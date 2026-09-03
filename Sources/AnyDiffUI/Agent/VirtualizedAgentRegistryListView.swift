import SwiftUI
import AppKit
import AnyDiffCore

public struct VirtualizedAgentRegistryListView: NSViewRepresentable {
    public var agents: [ACPRegistryAgentEntry]
    public var theme: Theme
    public var coordinator: AgentSessionCoordinator
    public var installingAgentId: String?
    public var installProgress: Double
    public var onInstall: (ACPRegistryAgentEntry) -> Void
    public var onStart: (ACPRegistryAgentEntry) -> Void
    public var onRemove: (ACPRegistryAgentEntry) -> Void
    public var onCancelInstall: ((ACPRegistryAgentEntry) -> Void)?

    public init(
        agents: [ACPRegistryAgentEntry],
        theme: Theme,
        coordinator: AgentSessionCoordinator,
        installingAgentId: String?,
        installProgress: Double = 0.0,
        onInstall: @escaping (ACPRegistryAgentEntry) -> Void,
        onStart: @escaping (ACPRegistryAgentEntry) -> Void,
        onRemove: @escaping (ACPRegistryAgentEntry) -> Void,
        onCancelInstall: ((ACPRegistryAgentEntry) -> Void)? = nil
    ) {
        self.agents = agents
        self.theme = theme
        self.coordinator = coordinator
        self.installingAgentId = installingAgentId
        self.installProgress = installProgress
        self.onInstall = onInstall
        self.onStart = onStart
        self.onRemove = onRemove
        self.onCancelInstall = onCancelInstall
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 76
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 4)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AgentColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = context.coordinator.tableView else { return }

        let agentsChanged = context.coordinator.cachedAgents != agents
        let themeChanged = context.coordinator.cachedThemeId != theme.id
        let installingChanged = context.coordinator.cachedInstallingId != installingAgentId
        let currentInstalledIds = Set(coordinator.allPresets.map(\.id))
        let installedChanged = context.coordinator.cachedInstalledIds != currentInstalledIds
        let progressChanged = abs(context.coordinator.cachedInstallProgress - installProgress) >= 0.01

        if agentsChanged || themeChanged || installingChanged || installedChanged || progressChanged || context.coordinator.needsFullReload {
            context.coordinator.cachedAgents = agents
            context.coordinator.cachedThemeId = theme.id
            context.coordinator.cachedInstallingId = installingAgentId
            context.coordinator.cachedInstallProgress = installProgress
            context.coordinator.cachedInstalledIds = currentInstalledIds
            context.coordinator.needsFullReload = false

            if !agentsChanged && !themeChanged && !installedChanged && (progressChanged || installingChanged),
               let installingId = installingAgentId,
               let row = agents.firstIndex(where: { $0.id == installingId }) {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            } else {
                tableView.reloadData()
            }
        }
    }

    public final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: VirtualizedAgentRegistryListView
        weak var tableView: NSTableView?
        var cachedAgents: [ACPRegistryAgentEntry] = []
        var cachedThemeId: String = ""
        var cachedInstallingId: String? = nil
        var cachedInstallProgress: Double = 0.0
        var cachedInstalledIds: Set<String> = []
        var needsFullReload: Bool = true

        init(_ parent: VirtualizedAgentRegistryListView) {
            self.parent = parent
            self.cachedAgents = parent.agents
            self.cachedThemeId = parent.theme.id
            self.cachedInstallingId = parent.installingAgentId
            self.cachedInstallProgress = parent.installProgress
            self.cachedInstalledIds = Set(parent.coordinator.allPresets.map(\.id))
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard let tableView = tableView else { return }
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.location != NSNotFound else { return }
            for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? AgentRegistryTableCellView {
                    cell.checkHover()
                }
            }
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            parent.agents.count
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("AgentRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? AgentTableRowView
            if rowView == nil {
                rowView = AgentTableRowView()
                rowView?.identifier = identifier
            }
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < parent.agents.count else { return nil }
            let agent = parent.agents[row]
            let identifier = NSUserInterfaceItemIdentifier("AgentTableCellView")

            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? AgentRegistryTableCellView
            if cell == nil {
                cell = AgentRegistryTableCellView()
                cell?.identifier = identifier
            }

            let isInstalled = parent.coordinator.isAgentInstalled(id: agent.id)
            let isInstalling = parent.installingAgentId == agent.id
            let isSupported = agent.isSupportedOnCurrentPlatform
            let progress = isInstalling ? parent.installProgress : 0.0

            cell?.configure(
                agent: agent,
                isInstalled: isInstalled,
                isInstalling: isInstalling,
                isSupported: isSupported,
                progress: progress,
                theme: parent.theme,
                onInstall: parent.onInstall,
                onStart: parent.onStart,
                onRemove: parent.onRemove,
                onCancelInstall: parent.onCancelInstall
            )

            return cell
        }
    }
}

// MARK: - Row View (Clean Transparent Selection)

final class AgentTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // Selection highlight is disabled
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent background
    }
}

// MARK: - Pill Badge View

final class PillBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(font: NSFont = .systemFont(ofSize: 9.5, weight: .semibold)) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4.5
        layer?.masksToBounds = true

        label.font = font
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 17)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, textColor: NSColor, bgColor: NSColor) {
        label.stringValue = text
        label.textColor = textColor
        layer?.backgroundColor = bgColor.cgColor
    }
}

// MARK: - Website Icon Button (Clean small icon, color-only hover)

final class IconLinkButton: NSButton {
    var onClick: (() -> Void)?
    var defaultTintColor: NSColor = .secondaryLabelColor { didSet { updateColor() } }
    var hoverTintColor: NSColor = .controlAccentColor { didSet { updateColor() } }

    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false

    init(symbolName: String = "globe", pointSize: CGFloat = 9.0) {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        imageScaling = .scaleProportionallyUpOrDown
        imagePosition = .imageOnly

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Website")?.withSymbolConfiguration(config) {
            img.isTemplate = true
            self.image = img
        }
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(handleClick)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 14),
            heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleClick() {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateColor()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateColor()
    }

    private func updateColor() {
        contentTintColor = isHovered ? hoverTintColor : defaultTintColor
    }
}

// MARK: - Modern Pill Action Button

final class ModernPillButton: NSButton {
    var defaultBgColor: NSColor = .clear { didSet { updateStyle() } }
    var hoverBgColor: NSColor = .clear
    var defaultBorderColor: NSColor = .clear { didSet { updateStyle() } }
    var hoverBorderColor: NSColor = .clear
    var defaultTextColor: NSColor = .labelColor { didSet { updateStyle() } }
    var hoverTextColor: NSColor = .labelColor
    var cornerRadiusValue: CGFloat = 6 { didSet { layer?.cornerRadius = cornerRadiusValue } }

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = cornerRadiusValue
        layer?.masksToBounds = true
    }

    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        if isEnabled {
            isHovered = true
            updateStyle()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
    }

    func updateStyle() {
        layer?.backgroundColor = (isHovered ? hoverBgColor : defaultBgColor).cgColor
        let border = isHovered ? hoverBorderColor : defaultBorderColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = (border == .clear) ? 0 : 1

        let textColor = isHovered ? hoverTextColor : defaultTextColor
        contentTintColor = textColor
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font ?? NSFont.systemFont(ofSize: 11.5, weight: .medium)
        ]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
    }
}

// MARK: - Download Progress Pill Button (Pill with percentage and Stop action)

final class DownloadProgressPillButton: NSControl {
    private let fillView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var fillWidthConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?

    var progress: Double = 0.0 {
        didSet {
            updateContent()
        }
    }
    private var isHovered = false
    var onCancel: (() -> Void)?

    var themeForeground: NSColor = .labelColor { didSet { updateContent() } }
    var themeGutterForeground: NSColor = .secondaryLabelColor { didSet { updateContent() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        fillView.wantsLayer = true
        fillView.layer?.cornerRadius = 6
        fillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fillView)

        let fillWidth = fillView.widthAnchor.constraint(equalToConstant: 0)
        fillWidthConstraint = fillWidth
        NSLayoutConstraint.activate([
            fillView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillView.topAnchor.constraint(equalTo: topAnchor),
            fillView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillWidth
        ])

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byClipping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2)
        ])
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateContent()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateContent()
    }

    override func mouseDown(with event: NSEvent) {
        onCancel?()
    }

    func updateContent() {
        let clamped = max(0.0, min(1.0, progress))
        let w = bounds.width > 0 ? bounds.width : 72
        fillWidthConstraint?.constant = w * CGFloat(clamped)

        if isHovered {
            layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.12).cgColor
            layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.40).cgColor
            fillView.layer?.backgroundColor = NSColor.clear.cgColor

            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: "Cancel ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.systemRed
            ]))
            attr.append(NSAttributedString(string: "✕", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor.systemRed
            ]))
            titleLabel.attributedStringValue = attr
            toolTip = "Cancel download"
        } else {
            let accent = NSColor.controlAccentColor
            layer?.backgroundColor = themeForeground.withAlphaComponent(0.04).cgColor
            layer?.borderColor = accent.withAlphaComponent(0.35).cgColor
            fillView.layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor

            let pct = Int(clamped * 100)
            let attr = NSMutableAttributedString()
            let pctText = pct >= 98 ? "99%" : "\(pct)%"
            attr.append(NSAttributedString(string: pctText, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: accent
            ]))
            attr.append(NSAttributedString(string: " ✕", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: themeGutterForeground
            ]))
            titleLabel.attributedStringValue = attr
            toolTip = "Downloading... Click to cancel"
        }
    }
}

// MARK: - Recycled Agent Table Cell View

final class AgentRegistryTableCellView: NSTableCellView {
    private let cardContainer = NSView()
    private let iconBox = NSView()
    private let iconImageView = NSImageView()

    private let textStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(labelWithString: "")
    private let bottomRow = NSStackView()
    private let versionBadge = PillBadgeView()
    private let typeBadge = PillBadgeView()
    private let linkButton = IconLinkButton(symbolName: "globe", pointSize: 9.0)
    private let authorLabel = NSTextField(labelWithString: "")

    private let buttonStack = NSStackView()
    private let installButton = ModernPillButton()
    private let removeButton = ModernPillButton()
    private let progressButton = DownloadProgressPillButton()

    private var currentAgent: ACPRegistryAgentEntry?
    private var onInstallCallback: ((ACPRegistryAgentEntry) -> Void)?
    private var onStartCallback: ((ACPRegistryAgentEntry) -> Void)?
    private var onRemoveCallback: ((ACPRegistryAgentEntry) -> Void)?
    private var onCancelInstallCallback: ((ACPRegistryAgentEntry) -> Void)?
    private var cardTrackingArea: NSTrackingArea?
    private var defaultCardBg: NSColor = .clear
    private var hoverCardBg: NSColor = .clear
    private var defaultCardBorder: NSColor = .clear
    private var hoverCardBorder: NSColor = .clear

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        wantsLayer = true

        // 1. Card container with smooth corners
        cardContainer.wantsLayer = true
        cardContainer.layer?.cornerRadius = 10
        cardContainer.layer?.masksToBounds = true
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardContainer)

        // 2. Icon box (square rounded)
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 8
        iconBox.layer?.masksToBounds = true
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(iconBox)

        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(iconImageView)

        // 3. Title label (full width, prominent)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 4. Description label (full width, clear secondary text)
        descLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descLabel.lineBreakMode = .byTruncatingTail
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 5. Badges & author row at the very bottom
        authorLabel.font = .systemFont(ofSize: 10, weight: .regular)
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 5
        bottomRow.addArrangedSubview(versionBadge)
        bottomRow.addArrangedSubview(typeBadge)
        bottomRow.addArrangedSubview(linkButton)
        bottomRow.addArrangedSubview(authorLabel)

        // 6. Text stack (vertically snug)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2.5
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(descLabel)
        textStack.addArrangedSubview(bottomRow)
        cardContainer.addSubview(textStack)

        // 7. Button stack
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 0
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(buttonStack)

        // Install button (modern pill)
        installButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        installButton.title = "Install"
        installButton.target = self
        installButton.action = #selector(handleInstall)
        installButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            installButton.widthAnchor.constraint(equalToConstant: 68),
            installButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        buttonStack.addArrangedSubview(installButton)

        // Remove button (modern ghost pill, exactly matching Install geometry)
        removeButton.font = .systemFont(ofSize: 11.5, weight: .medium)
        removeButton.title = "Remove"
        removeButton.target = self
        removeButton.action = #selector(handleRemove)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            removeButton.widthAnchor.constraint(equalToConstant: 68),
            removeButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        buttonStack.addArrangedSubview(removeButton)

        // Download progress button (modern pill with smooth progress fill, percentage, and Cancel on hover)
        progressButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressButton.widthAnchor.constraint(equalToConstant: 72),
            progressButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        progressButton.onCancel = { [weak self] in
            self?.handleCancelInstall()
        }
        buttonStack.addArrangedSubview(progressButton)

        // Autolayout Constraints
        NSLayoutConstraint.activate([
            // Card container fills cell with 12px horizontal inset and 2px vertical gap
            cardContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            cardContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cardContainer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            cardContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            // Icon box is vertically centered in the card
            iconBox.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor, constant: 12),
            iconBox.centerYAnchor.constraint(equalTo: cardContainer.centerYAnchor),
            iconBox.widthAnchor.constraint(equalToConstant: 38),
            iconBox.heightAnchor.constraint(equalToConstant: 38),

            // Icon image centered in box
            iconImageView.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 20),
            iconImageView.heightAnchor.constraint(equalToConstant: 20),

            // Text stack vertically centered in the card
            textStack.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 11),
            textStack.centerYAnchor.constraint(equalTo: cardContainer.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: buttonStack.leadingAnchor, constant: -10),

            // Button stack vertically centered on the right
            buttonStack.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor, constant: -12),
            buttonStack.centerYAnchor.constraint(equalTo: cardContainer.centerYAnchor)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = cardTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cardTrackingArea = area
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetHover()
    }

    func setHovered(_ hovered: Bool) {
        cardContainer.layer?.backgroundColor = (hovered ? hoverCardBg : defaultCardBg).cgColor
        cardContainer.layer?.borderColor = (hovered ? hoverCardBorder : defaultCardBorder).cgColor
    }

    func resetHover() {
        setHovered(false)
    }

    func checkHover() {
        guard let win = window else {
            resetHover()
            return
        }
        let mouseLoc = win.mouseLocationOutsideOfEventStream
        let localPoint = convert(mouseLoc, from: nil)
        let inside = bounds.contains(localPoint) && visibleRect.contains(localPoint)
        setHovered(inside)
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    func configure(
        agent: ACPRegistryAgentEntry,
        isInstalled: Bool,
        isInstalling: Bool,
        isSupported: Bool,
        progress: Double,
        theme: Theme,
        onInstall: @escaping (ACPRegistryAgentEntry) -> Void,
        onStart: @escaping (ACPRegistryAgentEntry) -> Void,
        onRemove: @escaping (ACPRegistryAgentEntry) -> Void,
        onCancelInstall: ((ACPRegistryAgentEntry) -> Void)? = nil
    ) {
        self.currentAgent = agent
        self.onInstallCallback = onInstall
        self.onStartCallback = onStart
        self.onRemoveCallback = onRemove
        self.onCancelInstallCallback = onCancelInstall

        // Card colors
        defaultCardBg = theme.foreground.withAlphaComponent(0.035)
        hoverCardBg = theme.foreground.withAlphaComponent(0.065)
        defaultCardBorder = theme.excerptHeaderBorder.withAlphaComponent(0.35)
        hoverCardBorder = theme.excerptHeaderBorder.withAlphaComponent(0.6)

        cardContainer.layer?.borderWidth = 1
        checkHover()

        // Title and author
        titleLabel.stringValue = agent.name
        titleLabel.textColor = theme.foreground

        if let authors = agent.authors, !authors.isEmpty {
            authorLabel.stringValue = authors.joined(separator: ", ")
            authorLabel.isHidden = false
        } else {
            authorLabel.stringValue = ""
            authorLabel.isHidden = true
        }
        authorLabel.textColor = theme.gutterForeground.withAlphaComponent(0.8)

        descLabel.stringValue = agent.description
        descLabel.textColor = theme.foreground.withAlphaComponent(0.85)

        // Version badge pill
        versionBadge.configure(
            text: "v\(agent.version)",
            textColor: theme.gutterForeground,
            bgColor: theme.foreground.withAlphaComponent(0.07)
        )

        // Type badge (npx vs bin)
        if agent.distribution.npx != nil {
            typeBadge.configure(
                text: "npx",
                textColor: NSColor.systemPurple,
                bgColor: NSColor.systemPurple.withAlphaComponent(0.14)
            )
            typeBadge.isHidden = false
        } else if agent.distribution.binary != nil {
            typeBadge.configure(
                text: "bin",
                textColor: NSColor.systemBlue,
                bgColor: NSColor.systemBlue.withAlphaComponent(0.14)
            )
            typeBadge.isHidden = false
        } else {
            typeBadge.isHidden = true
        }

        // Minimalist Link Icon to website / repository
        let rawTargetUrl: String? = {
            if let site = agent.website?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty {
                return site
            }
            if let repo = agent.repository?.trimmingCharacters(in: .whitespacesAndNewlines), !repo.isEmpty {
                return repo
            }
            return nil
        }()

        if let rawTargetUrl = rawTargetUrl {
            let finalUrlString = (rawTargetUrl.hasPrefix("http://") || rawTargetUrl.hasPrefix("https://")) ? rawTargetUrl : "https://" + rawTargetUrl
            if let targetUrl = URL(string: finalUrlString) {
                linkButton.isHidden = false
                linkButton.defaultTintColor = theme.gutterForeground.withAlphaComponent(0.65)
                linkButton.hoverTintColor = .controlAccentColor
                linkButton.toolTip = "Visit agent website: \(finalUrlString)"
                linkButton.onClick = {
                    NSWorkspace.shared.open(targetUrl)
                }
            } else {
                linkButton.isHidden = true
            }
        } else {
            linkButton.isHidden = true
        }

        // Icon & Brand styling
        let preset = agent.toAgentPreset()
        let brandColor = preset.nsColor(isDark: theme.isDark)
        iconBox.layer?.backgroundColor = brandColor.withAlphaComponent(0.13).cgColor
        iconBox.layer?.borderColor = brandColor.withAlphaComponent(0.24).cgColor
        iconBox.layer?.borderWidth = 1

        let agentId = agent.id

        // 1. Immediate local brand SVG or SF Symbol
        if let brandImage = AgentBrandIcons.image(for: preset.iconName) {
            brandImage.isTemplate = true
            iconImageView.image = brandImage
            iconImageView.contentTintColor = brandColor
        } else if let sfImage = NSImage(systemSymbolName: preset.iconName, accessibilityDescription: nil) {
            sfImage.isTemplate = true
            iconImageView.image = sfImage
            iconImageView.contentTintColor = brandColor
        } else if let fallbackImage = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil) ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) {
            fallbackImage.isTemplate = true
            iconImageView.image = fallbackImage
            iconImageView.contentTintColor = brandColor
        }

        // 2. Asynchronous fetch for custom registry icon SVG if provided
        if let iconUrl = agent.icon, !iconUrl.isEmpty {
            AgentIconLoader.shared.load(iconUrl) { [weak self, weak iconImageView = self.iconImageView] loadedImage in
                guard let self = self, self.currentAgent?.id == agentId, let image = loadedImage else { return }
                image.isTemplate = true
                iconImageView?.image = image
                iconImageView?.contentTintColor = brandColor
            }
        }

        // Install button styling
        let accent = NSColor.controlAccentColor
        installButton.defaultBgColor = accent.withAlphaComponent(0.12)
        installButton.hoverBgColor = accent.withAlphaComponent(0.24)
        installButton.defaultBorderColor = accent.withAlphaComponent(0.35)
        installButton.hoverBorderColor = accent.withAlphaComponent(0.55)
        installButton.defaultTextColor = accent
        installButton.hoverTextColor = accent

        // Remove button styling (Zed OutlinedGhost style, turning red on hover)
        removeButton.title = "Remove"
        removeButton.defaultBgColor = theme.foreground.withAlphaComponent(0.04)
        removeButton.hoverBgColor = NSColor.systemRed.withAlphaComponent(0.12)
        removeButton.defaultBorderColor = theme.excerptHeaderBorder.withAlphaComponent(0.30)
        removeButton.hoverBorderColor = NSColor.systemRed.withAlphaComponent(0.40)
        removeButton.defaultTextColor = theme.gutterForeground
        removeButton.hoverTextColor = NSColor.systemRed

        // Progress button styling
        progressButton.themeForeground = theme.foreground
        progressButton.themeGutterForeground = theme.gutterForeground
        progressButton.progress = progress

        // Button state handling: exactly one action visible at a time
        if isInstalling {
            installButton.isHidden = true
            removeButton.isHidden = true
            progressButton.isHidden = false
            progressButton.updateContent()
        } else if isInstalled {
            installButton.isHidden = true
            removeButton.isHidden = false
            progressButton.isHidden = true
        } else {
            installButton.isHidden = false
            removeButton.isHidden = true
            progressButton.isHidden = true

            if !isSupported {
                installButton.isEnabled = false
                installButton.title = "Unavailable"
                installButton.defaultBgColor = theme.foreground.withAlphaComponent(0.04)
                installButton.defaultBorderColor = .clear
                installButton.defaultTextColor = theme.gutterForeground
                installButton.hoverTextColor = theme.gutterForeground
            } else {
                installButton.isEnabled = true
                installButton.title = "Install"
            }
        }
        installButton.updateStyle()
        removeButton.updateStyle()
    }

    @objc private func handleInstall() {
        guard let agent = currentAgent else { return }
        if agent.distribution.npx != nil {
            installButton.isHidden = true
            removeButton.isHidden = false
            progressButton.isHidden = true
            removeButton.updateStyle()
        } else if agent.distribution.binary != nil {
            installButton.isHidden = true
            removeButton.isHidden = true
            progressButton.isHidden = false
            progressButton.progress = 0.0
            progressButton.updateContent()
        }
        onInstallCallback?(agent)
    }

    @objc private func handleCancelInstall() {
        guard let agent = currentAgent else { return }
        progressButton.isHidden = true
        installButton.isHidden = false
        installButton.isEnabled = true
        installButton.title = "Install"
        installButton.updateStyle()
        onCancelInstallCallback?(agent)
    }

    @objc private func handleRemove() {
        guard let agent = currentAgent else { return }
        removeButton.isHidden = true
        progressButton.isHidden = true
        installButton.isHidden = false
        installButton.isEnabled = true
        installButton.title = "Install"
        installButton.updateStyle()
        onRemoveCallback?(agent)
    }
}
