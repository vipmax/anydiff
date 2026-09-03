import SwiftUI
import AppKit
import AnyDiffCore

// MARK: - Virtualized Saved Sessions List View

public struct VirtualizedSavedSessionsListView: NSViewRepresentable {
    public var sessions: [ACPSavedSessionItem]
    public var preset: AgentPreset
    public var theme: Theme
    public var loadingSessionId: String?
    public var onSelect: (ACPSavedSessionItem) -> Void

    public init(
        sessions: [ACPSavedSessionItem],
        preset: AgentPreset,
        theme: Theme,
        loadingSessionId: String?,
        onSelect: @escaping (ACPSavedSessionItem) -> Void
    ) {
        self.sessions = sessions
        self.preset = preset
        self.theme = theme
        self.loadingSessionId = loadingSessionId
        self.onSelect = onSelect
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
        tableView.rowHeight = 56
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 6)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SessionColumn"))
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

        let sessionsChanged = context.coordinator.cachedSessions != sessions
        let themeChanged = context.coordinator.cachedThemeId != theme.id
        let presetChanged = context.coordinator.cachedPresetId != preset.id
        let loadingChanged = context.coordinator.cachedLoadingSessionId != loadingSessionId

        if themeChanged || presetChanged || loadingChanged || context.coordinator.needsFullReload {
            context.coordinator.cachedSessions = sessions
            context.coordinator.cachedThemeId = theme.id
            context.coordinator.cachedPresetId = preset.id
            context.coordinator.cachedLoadingSessionId = loadingSessionId
            context.coordinator.needsFullReload = false
            tableView.reloadData()
        } else if sessionsChanged {
            let oldSessions = context.coordinator.cachedSessions
            context.coordinator.cachedSessions = sessions
            if sessions.count > oldSessions.count && sessions.starts(with: oldSessions) {
                let indexSet = IndexSet(integersIn: oldSessions.count..<sessions.count)
                tableView.insertRows(at: indexSet, withAnimation: .effectFade)
            } else {
                tableView.reloadData()
            }
        }
    }

    public final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: VirtualizedSavedSessionsListView
        weak var tableView: NSTableView?
        var cachedSessions: [ACPSavedSessionItem] = []
        var cachedThemeId: String = ""
        var cachedPresetId: String = ""
        var cachedLoadingSessionId: String? = nil
        var needsFullReload: Bool = true

        init(_ parent: VirtualizedSavedSessionsListView) {
            self.parent = parent
            self.cachedSessions = parent.sessions
            self.cachedThemeId = parent.theme.id
            self.cachedPresetId = parent.preset.id
            self.cachedLoadingSessionId = parent.loadingSessionId
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard let tableView = tableView else { return }
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.location != NSNotFound else { return }
            for row in visibleRange.location..<(visibleRange.location + visibleRange.length) {
                if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SavedSessionTableCellView {
                    cell.checkHover()
                }
            }
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            parent.sessions.count
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("SessionRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? SavedSessionTableRowView
            if rowView == nil {
                rowView = SavedSessionTableRowView()
                rowView?.identifier = identifier
            }
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < parent.sessions.count else { return nil }
            let session = parent.sessions[row]
            let identifier = NSUserInterfaceItemIdentifier("SavedSessionTableCellView")

            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SavedSessionTableCellView
            if cell == nil {
                cell = SavedSessionTableCellView()
                cell?.identifier = identifier
            }

            let isLoading = parent.loadingSessionId == session.sessionId

            cell?.configure(
                session: session,
                preset: parent.preset,
                theme: parent.theme,
                isLoading: isLoading,
                onSelect: parent.onSelect
            )

            return cell
        }
    }
}

// MARK: - Row View (Clean Transparent Selection)

final class SavedSessionTableRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // Selection highlight disabled for custom card look
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent background
    }
}

// MARK: - Interactive Card Button

final class SavedSessionCardButton: NSControl {
    var onSelect: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var defaultBgColor: NSColor = .clear
    var hoverBgColor: NSColor = .clear
    var defaultBorderColor: NSColor = .clear
    var hoverBorderColor: NSColor = .clear

    private var trackingArea: NSTrackingArea?
    private(set) var isHovered: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        updateAppearance()
        onHoverChanged?(hovered)
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

    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.72
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1.0
        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            onSelect?()
        }
    }

    func updateAppearance() {
        layer?.backgroundColor = (isHovered ? hoverBgColor : defaultBgColor).cgColor
        let border = isHovered ? hoverBorderColor : defaultBorderColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1
    }
}

// MARK: - Recycled Saved Session Table Cell View

final class SavedSessionTableCellView: NSTableCellView {
    private let cardButton = SavedSessionCardButton()
    private let iconCircle = NSView()
    private let iconImageView = NSImageView()
    private let progressIndicator = NSProgressIndicator()

    private let textStack = NSStackView()
    private let titleRow = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let idBadge = PillBadgeView(font: .monospacedSystemFont(ofSize: 9.5, weight: .regular))

    private let metaRow = NSStackView()
    private let dateStack = NSStackView()
    private let dateIcon = NSImageView()
    private let dateLabel = NSTextField(labelWithString: "")

    private let folderStack = NSStackView()
    private let folderIcon = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "")

    private let chevronImageView = NSImageView()
    private var chevronTrailingConstraint: NSLayoutConstraint?

    private var currentSession: ACPSavedSessionItem?
    private var currentTheme: Theme?
    private var presetColor: NSColor = .controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cardButton.resetHover()
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        iconImageView.isHidden = false
    }

    func checkHover() {
        cardButton.checkHover()
    }

    private func setupViews() {
        wantsLayer = true

        // 1. Card container button
        cardButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardButton)

        cardButton.onHoverChanged = { [weak self] isHovered in
            self?.updateHoverState(isHovered)
        }

        // 2. Icon circle indicator (32x32)
        iconCircle.wantsLayer = true
        iconCircle.layer?.cornerRadius = 16
        iconCircle.layer?.masksToBounds = true
        iconCircle.layer?.borderWidth = 1
        iconCircle.translatesAutoresizingMaskIntoConstraints = false
        cardButton.addSubview(iconCircle)

        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        let clockConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        if let clockImg = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Saved Session")?.withSymbolConfiguration(clockConfig) {
            clockImg.isTemplate = true
            iconImageView.image = clockImg
        }
        iconCircle.addSubview(iconImageView)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        iconCircle.addSubview(progressIndicator)

        // 3. Title row
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(idBadge)

        // 4. Meta row (date + folder)
        dateStack.orientation = .horizontal
        dateStack.alignment = .centerY
        dateStack.spacing = 3

        let calConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        if let calImg = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Date")?.withSymbolConfiguration(calConfig) {
            calImg.isTemplate = true
            dateIcon.image = calImg
        }
        dateIcon.imageScaling = .scaleProportionallyUpOrDown
        dateIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dateIcon.widthAnchor.constraint(equalToConstant: 10),
            dateIcon.heightAnchor.constraint(equalToConstant: 10)
        ])
        dateLabel.font = .systemFont(ofSize: 10, weight: .regular)

        dateStack.addArrangedSubview(dateIcon)
        dateStack.addArrangedSubview(dateLabel)

        folderStack.orientation = .horizontal
        folderStack.alignment = .centerY
        folderStack.spacing = 3

        let folderConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        if let folderImg = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?.withSymbolConfiguration(folderConfig) {
            folderImg.isTemplate = true
            folderIcon.image = folderImg
        }
        folderIcon.imageScaling = .scaleProportionallyUpOrDown
        folderIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            folderIcon.widthAnchor.constraint(equalToConstant: 10),
            folderIcon.heightAnchor.constraint(equalToConstant: 10)
        ])
        folderLabel.font = .systemFont(ofSize: 10, weight: .regular)
        folderLabel.lineBreakMode = .byTruncatingMiddle

        folderStack.addArrangedSubview(folderIcon)
        folderStack.addArrangedSubview(folderLabel)

        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 10
        metaRow.addArrangedSubview(dateStack)
        metaRow.addArrangedSubview(folderStack)

        // 5. Text stack (vertical)
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleRow)
        textStack.addArrangedSubview(metaRow)
        cardButton.addSubview(textStack)

        // 6. Right chevron
        let chevConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        if let chevImg = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Resume")?.withSymbolConfiguration(chevConfig) {
            chevImg.isTemplate = true
            chevronImageView.image = chevImg
        }
        chevronImageView.imageScaling = .scaleProportionallyUpOrDown
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false
        cardButton.addSubview(chevronImageView)

        // Layout constraints
        let trailingConstraint = chevronImageView.trailingAnchor.constraint(equalTo: cardButton.trailingAnchor, constant: -14)
        chevronTrailingConstraint = trailingConstraint

        NSLayoutConstraint.activate([
            // Card container pinned to edges with 16pt horizontal padding
            cardButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            cardButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            cardButton.topAnchor.constraint(equalTo: topAnchor),
            cardButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Icon circle vertically centered on left
            iconCircle.leadingAnchor.constraint(equalTo: cardButton.leadingAnchor, constant: 12),
            iconCircle.centerYAnchor.constraint(equalTo: cardButton.centerYAnchor),
            iconCircle.widthAnchor.constraint(equalToConstant: 32),
            iconCircle.heightAnchor.constraint(equalToConstant: 32),

            iconImageView.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            progressIndicator.centerXAnchor.constraint(equalTo: iconCircle.centerXAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: iconCircle.centerYAnchor),

            // Text stack vertically centered
            textStack.leadingAnchor.constraint(equalTo: iconCircle.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: cardButton.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: chevronImageView.leadingAnchor, constant: -10),

            // Chevron on the right
            trailingConstraint,
            chevronImageView.centerYAnchor.constraint(equalTo: cardButton.centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 14),
            chevronImageView.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    func configure(
        session: ACPSavedSessionItem,
        preset: AgentPreset,
        theme: Theme,
        isLoading: Bool,
        onSelect: @escaping (ACPSavedSessionItem) -> Void
    ) {
        self.currentSession = session
        self.currentTheme = theme
        let brandColor = preset.nsColor(isDark: theme.isDark)
        self.presetColor = brandColor

        cardButton.defaultBgColor = theme.foreground.withAlphaComponent(0.035)
        cardButton.hoverBgColor = theme.foreground.withAlphaComponent(0.07)
        let borderColor = theme.excerptHeaderBorder.withAlphaComponent(0.35)
        cardButton.defaultBorderColor = borderColor
        cardButton.hoverBorderColor = borderColor
        cardButton.onSelect = { onSelect(session) }
        cardButton.checkHover()
        cardButton.updateAppearance()

        // Title and ID Badge
        titleLabel.stringValue = session.displayTitle
        titleLabel.textColor = theme.foreground

        let isGenericTitle = isGenericSessionTitle(item: session)
        if !isGenericTitle {
            idBadge.isHidden = false
            idBadge.configure(
                text: session.shortId,
                textColor: theme.gutterForeground.withAlphaComponent(0.8),
                bgColor: theme.foreground.withAlphaComponent(0.06)
            )
        } else {
            idBadge.isHidden = true
        }

        // Meta info (date)
        if !session.formattedDate.isEmpty {
            dateStack.isHidden = false
            dateLabel.stringValue = session.formattedDate
            dateLabel.textColor = theme.gutterForeground
            dateIcon.contentTintColor = theme.gutterForeground
        } else {
            dateStack.isHidden = true
        }

        // Meta info (cwd)
        if let cwd = session.cwd, !cwd.isEmpty {
            folderStack.isHidden = false
            let lastPathComponent = (cwd as NSString).lastPathComponent
            folderLabel.stringValue = lastPathComponent
            folderLabel.textColor = theme.gutterForeground.withAlphaComponent(0.7)
            folderIcon.contentTintColor = theme.gutterForeground.withAlphaComponent(0.7)
        } else {
            folderStack.isHidden = true
        }

        // Loading or icon state
        if isLoading {
            iconImageView.isHidden = true
            progressIndicator.isHidden = false
            progressIndicator.startAnimation(nil)
        } else {
            iconImageView.isHidden = false
            progressIndicator.isHidden = true
            progressIndicator.stopAnimation(nil)
        }

        updateHoverState(cardButton.isHovered)
    }

    private func updateHoverState(_ isHovered: Bool) {
        let fillAlpha: CGFloat = isHovered ? 0.22 : 0.12
        let strokeAlpha: CGFloat = isHovered ? 0.60 : 0.25
        iconCircle.layer?.backgroundColor = presetColor.withAlphaComponent(fillAlpha).cgColor
        iconCircle.layer?.borderColor = presetColor.withAlphaComponent(strokeAlpha).cgColor
        iconImageView.contentTintColor = presetColor

        if let theme = currentTheme {
            chevronImageView.contentTintColor = isHovered
                ? theme.foreground
                : theme.gutterForeground.withAlphaComponent(0.85)
        } else {
            chevronImageView.contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
        }
        chevronTrailingConstraint?.constant = isHovered ? -12 : -14
    }

    private func isGenericSessionTitle(item: ACPSavedSessionItem) -> Bool {
        let t = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let idLower = item.sessionId.lowercased()
        let shortId = item.shortId.lowercased()
        return t == "session \(shortId)" || t == "session \(idLower)" || t == shortId || t == idLower || (t.hasPrefix("session ") && t.count <= 18)
    }
}
