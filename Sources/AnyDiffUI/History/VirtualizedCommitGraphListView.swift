import SwiftUI
import AppKit
import AnyDiffCore

public struct VirtualizedCommitGraphListView: NSViewRepresentable {
    public var rows: [GraphRow]
    public var directory: String
    public var selectedCommitHash: String?
    public var isWorkingChangesSelected: Bool
    public var workingChangesFileCount: Int
    public var theme: Theme
    public var onSelectCommit: (GitCommit) -> Void
    public var onSelectCommitFile: ((GitCommit, String) -> Void)?
    public var onSelectWorkingChanges: () -> Void
    public var onShowCommitDetails: ((GitCommit) -> Void)?
    public var onLoadMore: (() -> Void)?

    public init(
        rows: [GraphRow],
        directory: String = "",
        selectedCommitHash: String?,
        isWorkingChangesSelected: Bool,
        workingChangesFileCount: Int = 0,
        theme: Theme,
        onSelectCommit: @escaping (GitCommit) -> Void,
        onSelectCommitFile: ((GitCommit, String) -> Void)? = nil,
        onSelectWorkingChanges: @escaping () -> Void,
        onShowCommitDetails: ((GitCommit) -> Void)? = nil,
        onLoadMore: (() -> Void)? = nil
    ) {
        self.rows = rows
        self.directory = directory
        self.selectedCommitHash = selectedCommitHash
        self.isWorkingChangesSelected = isWorkingChangesSelected
        self.workingChangesFileCount = workingChangesFileCount
        self.theme = theme
        self.onSelectCommit = onSelectCommit
        self.onSelectCommitFile = onSelectCommitFile
        self.onSelectWorkingChanges = onSelectWorkingChanges
        self.onShowCommitDetails = onShowCommitDetails
        self.onLoadMore = onLoadMore
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
        tableView.rowHeight = 44
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommitColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.tableClicked(_:))

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView

        // Dismiss commit details popover on scroll
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewWillStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.anyScrollViewWillStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: nil
        )

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = context.coordinator.tableView else { return }

        let rowsChanged = context.coordinator.cachedRows.count != rows.count || context.coordinator.cachedRowIds != rows.map(\.id)
        let themeChanged = context.coordinator.cachedThemeId != theme.id
        let countChanged = context.coordinator.cachedWorkingChangesCount != workingChangesFileCount

        if rowsChanged || themeChanged || countChanged {
            CommitGraphTableCellView.dismissActivePopover()
            context.coordinator.cachedRows = rows
            context.coordinator.cachedRowIds = rows.map(\.id)
            context.coordinator.cachedThemeId = theme.id
            context.coordinator.cachedWorkingChangesCount = workingChangesFileCount
            tableView.reloadData()
        }

        // Sync table selection
        let targetRowIndex: Int?
        if isWorkingChangesSelected {
            targetRowIndex = rows.firstIndex(where: { $0.isWorkingChanges })
        } else if let hash = selectedCommitHash {
            targetRowIndex = rows.firstIndex(where: { $0.commit?.hash == hash })
        } else {
            targetRowIndex = nil
        }

        if let idx = targetRowIndex {
            if tableView.selectedRow != idx {
                context.coordinator.isSyncingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
                context.coordinator.isSyncingSelection = false
            }
        } else if tableView.selectedRow != -1 {
            context.coordinator.isSyncingSelection = true
            tableView.deselectAll(nil)
            context.coordinator.isSyncingSelection = false
        }
    }

    public final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: VirtualizedCommitGraphListView
        weak var tableView: NSTableView?
        var isSyncingSelection: Bool = false
        var cachedRows: [GraphRow] = []
        var cachedRowIds: [String] = []
        var cachedThemeId: String = ""
        var cachedWorkingChangesCount: Int = 0

        init(_ parent: VirtualizedCommitGraphListView) {
            self.parent = parent
            self.cachedRows = parent.rows
            self.cachedRowIds = parent.rows.map(\.id)
            self.cachedThemeId = parent.theme.id
            self.cachedWorkingChangesCount = parent.workingChangesFileCount
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            CommitGraphTableCellView.dismissActivePopover()
        }

        @objc func scrollViewWillStartLiveScroll(_ notification: Notification) {
            CommitGraphTableCellView.dismissActivePopover()
        }

        @objc func scrollViewDidLiveScroll(_ notification: Notification) {
            CommitGraphTableCellView.dismissActivePopover()
        }

        @objc func anyScrollViewWillStartLiveScroll(_ notification: Notification) {
            guard let sv = notification.object as? NSScrollView else { return }
            if let popover = CommitGraphTableCellView.activePopover,
               let popoverWindow = popover.contentViewController?.view.window,
               sv.window == popoverWindow {
                // Ignore scrolling within the popover itself
                return
            }
            CommitGraphTableCellView.dismissActivePopover()
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("CommitRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitTableRowView
            if rowView == nil {
                rowView = CommitTableRowView()
                rowView?.identifier = identifier
            }
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < parent.rows.count else { return nil }

            // Infinite scroll trigger: when nearing bottom
            if row >= parent.rows.count - 25 {
                parent.onLoadMore?()
            }

            let graphRow = parent.rows[row]
            let identifier = NSUserInterfaceItemIdentifier("CommitGraphCellView")
            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CommitGraphTableCellView
            if cell == nil {
                cell = CommitGraphTableCellView()
                cell?.identifier = identifier
            }

            cell?.configure(
                row: graphRow,
                directory: parent.directory,
                theme: parent.theme,
                workingChangesCount: parent.workingChangesFileCount,
                onSelectCommit: parent.onSelectCommit,
                onSelectCommitFile: parent.onSelectCommitFile,
                onShowDetails: parent.onShowCommitDetails
            )

            return cell
        }

        @objc func tableClicked(_ sender: NSTableView) {
            CommitGraphTableCellView.dismissActivePopover()
            let row = sender.clickedRow
            guard row >= 0 && row < parent.rows.count else { return }
            let item = parent.rows[row]
            if item.isWorkingChanges {
                parent.onSelectWorkingChanges()
            } else if let commit = item.commit {
                parent.onSelectCommit(commit)
            }
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            CommitGraphTableCellView.dismissActivePopover()
            guard let tableView = tableView else { return }
            let selectedRow = tableView.selectedRow
            guard selectedRow >= 0 && selectedRow < parent.rows.count else { return }
            let item = parent.rows[selectedRow]
            if item.isWorkingChanges {
                guard !parent.isWorkingChangesSelected else { return }
                parent.onSelectWorkingChanges()
            } else if let commit = item.commit {
                guard parent.selectedCommitHash != commit.hash else { return }
                parent.onSelectCommit(commit)
            }
        }
    }
}

// MARK: - Custom Table Row View for History with balanced selection & hover
final class CommitTableRowView: NSTableRowView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingArea == nil {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            let selectionRect = bounds.insetBy(dx: 6, dy: 2)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent default background
    }
}

// MARK: - Reusable Ref Badge View (Zero-Alloc during scroll)
final class RefBadgeItemView: NSView {
    private static let branchImage = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
    private static let tagImage = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 9),
            icon.heightAnchor.constraint(equalToConstant: 9),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1.5)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with ref: GitRef) {
        let isHead = ref.type == .head
        let bgColor = isHead ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.secondaryLabelColor.withAlphaComponent(0.12)
        layer?.backgroundColor = bgColor.cgColor

        let tint = isHead ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        icon.image = ref.type.isTag ? Self.tagImage : Self.branchImage
        icon.contentTintColor = tint
        label.textColor = tint
        label.stringValue = ref.shortName
    }
}

// MARK: - Recycled Two-Level Commit Cell View
final class CommitGraphTableCellView: NSTableCellView {
    private let graphTrackView = GraphTrackView()
    private var graphWidthConstraint: NSLayoutConstraint?

    // Outer vertical stack containing Row 1 (summary) and Row 2 (metadata)
    private let containerStack = NSStackView()

    // Row 1: Top line
    private let topRowStack = NSStackView()
    private let workingIconView = NSImageView()
    private let refBadgeStack = NSStackView()
    private let refBadge0 = RefBadgeItemView()
    private let refBadge1 = RefBadgeItemView()
    private let summaryLabel = NSTextField(labelWithString: "")

    // Row 2: Bottom line (hash, author, reltime, N changes, +- figures)
    private let bottomRowStack = NSStackView()
    private let hashLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let dotLabel1 = NSTextField(labelWithString: "•")
    private let timeLabel = NSTextField(labelWithString: "")
    private let dotLabel2 = NSTextField(labelWithString: "•")
    private let changesCountLabel = NSTextField(labelWithString: "")
    private let additionsLabel = NSTextField(labelWithString: "")
    private let deletionsLabel = NSTextField(labelWithString: "")
    private let infoButton = NSButton()

    private var currentCommit: GitCommit?
    private var currentDirectory: String = ""
    private var currentTheme: Theme?
    private var onSelectCommitAction: ((GitCommit) -> Void)?
    private var onSelectCommitFileAction: ((GitCommit, String) -> Void)?
    private var onShowDetailsAction: ((GitCommit) -> Void)?
    static var activePopover: NSPopover?
    static weak var activePopoverAnchor: CommitGraphTableCellView?

    public static func dismissActivePopover() {
        let close = {
            if let existing = activePopover, existing.isShown {
                existing.close()
            }
            activePopover = nil
            activePopoverAnchor = nil
        }
        if Thread.isMainThread {
            close()
        } else {
            DispatchQueue.main.async(execute: close)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if Self.activePopoverAnchor === self {
            Self.dismissActivePopover()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && Self.activePopoverAnchor === self {
            Self.dismissActivePopover()
        }
    }

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

        // 1. Graph Track View
        graphTrackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(graphTrackView)

        let initialWidth = GraphTrackView.preferredWidth(for: 1)
        let widthConstraint = graphTrackView.widthAnchor.constraint(equalToConstant: initialWidth)
        widthConstraint.isActive = true
        self.graphWidthConstraint = widthConstraint

        // 2. Working icon view
        workingIconView.imageScaling = .scaleProportionallyUpOrDown
        workingIconView.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Working Changes")
        workingIconView.contentTintColor = NSColor(red: 1.00, green: 0.65, blue: 0.20, alpha: 1.0)
        workingIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            workingIconView.widthAnchor.constraint(equalToConstant: 12),
            workingIconView.heightAnchor.constraint(equalToConstant: 12)
        ])
        workingIconView.setContentHuggingPriority(.required, for: .horizontal)
        workingIconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        // 3. Top Row Subviews
        refBadgeStack.orientation = .horizontal
        refBadgeStack.alignment = .centerY
        refBadgeStack.spacing = 3
        refBadgeStack.translatesAutoresizingMaskIntoConstraints = false
        refBadgeStack.setContentHuggingPriority(.required, for: .horizontal)
        refBadgeStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        refBadgeStack.addArrangedSubview(refBadge0)
        refBadgeStack.addArrangedSubview(refBadge1)
        refBadge0.isHidden = true
        refBadge1.isHidden = true

        summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
        summaryLabel.alignment = .left
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        topRowStack.orientation = .horizontal
        topRowStack.alignment = .centerY
        topRowStack.spacing = 5
        topRowStack.translatesAutoresizingMaskIntoConstraints = false
        topRowStack.addArrangedSubview(workingIconView)
        topRowStack.addArrangedSubview(refBadgeStack)
        topRowStack.addArrangedSubview(summaryLabel)

        // 4. Bottom Row Subviews (hash, author, reltime, N changes, +- figures, infoButton)
        hashLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hashLabel.alignment = .left
        hashLabel.textColor = .secondaryLabelColor
        hashLabel.translatesAutoresizingMaskIntoConstraints = false
        hashLabel.setContentHuggingPriority(.required, for: .horizontal)
        hashLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        authorLabel.font = .systemFont(ofSize: 10, weight: .regular)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.lineBreakMode = .byTruncatingTail
        authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        authorLabel.translatesAutoresizingMaskIntoConstraints = false

        dotLabel1.font = .systemFont(ofSize: 9, weight: .regular)
        dotLabel1.textColor = .tertiaryLabelColor
        dotLabel1.translatesAutoresizingMaskIntoConstraints = false
        dotLabel1.setContentHuggingPriority(.required, for: .horizontal)
        dotLabel1.setContentCompressionResistancePriority(.required, for: .horizontal)

        timeLabel.font = .systemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        dotLabel2.font = .systemFont(ofSize: 9, weight: .regular)
        dotLabel2.textColor = .tertiaryLabelColor
        dotLabel2.translatesAutoresizingMaskIntoConstraints = false
        dotLabel2.setContentHuggingPriority(.required, for: .horizontal)
        dotLabel2.setContentCompressionResistancePriority(.required, for: .horizontal)

        changesCountLabel.font = .systemFont(ofSize: 10, weight: .regular)
        changesCountLabel.textColor = .secondaryLabelColor
        changesCountLabel.translatesAutoresizingMaskIntoConstraints = false
        changesCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        changesCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        additionsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        additionsLabel.textColor = NSColor.systemGreen
        additionsLabel.translatesAutoresizingMaskIntoConstraints = false
        additionsLabel.setContentHuggingPriority(.required, for: .horizontal)
        additionsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        deletionsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        deletionsLabel.textColor = NSColor.systemRed
        deletionsLabel.translatesAutoresizingMaskIntoConstraints = false
        deletionsLabel.setContentHuggingPriority(.required, for: .horizontal)
        deletionsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        infoButton.isBordered = false
        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Commit Details")
        infoButton.contentTintColor = .tertiaryLabelColor
        infoButton.target = self
        infoButton.action = #selector(infoButtonClicked)
        infoButton.toolTip = "View commit details"
        infoButton.imageScaling = .scaleProportionallyUpOrDown
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoButton.widthAnchor.constraint(equalToConstant: 13),
            infoButton.heightAnchor.constraint(equalToConstant: 13)
        ])
        infoButton.setContentHuggingPriority(.required, for: .horizontal)
        infoButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        bottomRowStack.orientation = .horizontal
        bottomRowStack.alignment = .centerY
        bottomRowStack.spacing = 5
        bottomRowStack.translatesAutoresizingMaskIntoConstraints = false

        bottomRowStack.addArrangedSubview(hashLabel)
        bottomRowStack.addArrangedSubview(authorLabel)
        bottomRowStack.addArrangedSubview(dotLabel1)
        bottomRowStack.addArrangedSubview(timeLabel)
        bottomRowStack.addArrangedSubview(dotLabel2)
        bottomRowStack.addArrangedSubview(changesCountLabel)
        bottomRowStack.addArrangedSubview(additionsLabel)
        bottomRowStack.addArrangedSubview(deletionsLabel)
        bottomRowStack.addArrangedSubview(infoButton)

        // 5. Container Stack (vertical)
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 2
        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.addArrangedSubview(topRowStack)
        containerStack.addArrangedSubview(bottomRowStack)
        addSubview(containerStack)

        NSLayoutConstraint.activate([
            graphTrackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            graphTrackView.topAnchor.constraint(equalTo: topAnchor),
            graphTrackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            containerStack.leadingAnchor.constraint(equalTo: graphTrackView.trailingAnchor, constant: 4),
            containerStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            containerStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    public func configure(
        row: GraphRow,
        directory: String = "",
        theme: Theme,
        workingChangesCount: Int,
        onSelectCommit: ((GitCommit) -> Void)? = nil,
        onSelectCommitFile: ((GitCommit, String) -> Void)? = nil,
        onShowDetails: ((GitCommit) -> Void)? = nil
    ) {
        self.currentCommit = row.commit
        self.currentDirectory = directory
        self.currentTheme = theme
        self.onSelectCommitAction = onSelectCommit
        self.onSelectCommitFileAction = onSelectCommitFile
        self.onShowDetailsAction = onShowDetails

        // Configure graph track
        let graphWidth = GraphTrackView.preferredWidth(for: row.totalLanes)
        graphWidthConstraint?.constant = graphWidth
        graphTrackView.graphRow = row

        if row.isWorkingChanges {
            workingIconView.isHidden = false
            topRowStack.setVisibilityPriority(.mustHold, for: workingIconView)

            refBadgeStack.isHidden = true
            topRowStack.setVisibilityPriority(.notVisible, for: refBadgeStack)
            refBadge0.isHidden = true
            refBadge1.isHidden = true

            hashLabel.isHidden = true
            bottomRowStack.setVisibilityPriority(.notVisible, for: hashLabel)

            infoButton.isHidden = true
            bottomRowStack.setVisibilityPriority(.notVisible, for: infoButton)

            summaryLabel.stringValue = "Working Changes"
            summaryLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            summaryLabel.textColor = Color(theme.foreground).nsColor

            authorLabel.stringValue = "Uncommitted local changes"
            timeLabel.isHidden = true
            bottomRowStack.setVisibilityPriority(.notVisible, for: timeLabel)
            dotLabel1.isHidden = true
            bottomRowStack.setVisibilityPriority(.notVisible, for: dotLabel1)

            let countText = workingChangesCount > 0 ? "\(workingChangesCount)" : "Clean"
            changesCountLabel.stringValue = countText
            changesCountLabel.toolTip = workingChangesCount > 0 ? "\(workingChangesCount) \(workingChangesCount == 1 ? "file" : "files") changed" : "Working tree clean"
            changesCountLabel.isHidden = false
            bottomRowStack.setVisibilityPriority(.mustHold, for: changesCountLabel)
            dotLabel2.isHidden = false
            bottomRowStack.setVisibilityPriority(.mustHold, for: dotLabel2)

            additionsLabel.isHidden = true
            bottomRowStack.setVisibilityPriority(.notVisible, for: additionsLabel)
            deletionsLabel.isHidden = true
            bottomRowStack.setVisibilityPriority(.notVisible, for: deletionsLabel)
        } else if let commit = row.commit {
            workingIconView.isHidden = true
            topRowStack.setVisibilityPriority(.notVisible, for: workingIconView)

            // Top Row: Commit text
            summaryLabel.stringValue = commit.summary
            summaryLabel.font = .systemFont(ofSize: 12, weight: .medium)
            summaryLabel.textColor = Color(theme.foreground).nsColor

            // Configure ref badges (zero-alloc using pre-allocated badge views)
            let refs = commit.refs
            if refs.isEmpty {
                refBadgeStack.isHidden = true
                topRowStack.setVisibilityPriority(.notVisible, for: refBadgeStack)
                refBadge0.isHidden = true
                refBadge1.isHidden = true
            } else {
                refBadgeStack.isHidden = false
                topRowStack.setVisibilityPriority(.mustHold, for: refBadgeStack)
                refBadge0.configure(with: refs[0])
                refBadge0.isHidden = false
                if refs.count > 1 {
                    refBadge1.configure(with: refs[1])
                    refBadge1.isHidden = false
                } else {
                    refBadge1.isHidden = true
                }
            }

            // Bottom Row: hash, author, reltime, N changes, +- figures, infoButton
            hashLabel.isHidden = false
            bottomRowStack.setVisibilityPriority(.mustHold, for: hashLabel)
            hashLabel.stringValue = commit.shortHash
            hashLabel.textColor = .secondaryLabelColor

            authorLabel.stringValue = commit.authorName.isEmpty ? "unknown" : commit.authorName
            timeLabel.stringValue = Self.formatRelativeDate(commit.date)
            timeLabel.toolTip = Self.fullDateFormatter.string(from: commit.date)
            timeLabel.isHidden = false
            bottomRowStack.setVisibilityPriority(.mustHold, for: timeLabel)
            dotLabel1.isHidden = false
            bottomRowStack.setVisibilityPriority(.mustHold, for: dotLabel1)

            if commit.filesChanged > 0 {
                changesCountLabel.stringValue = "\(commit.filesChanged)"
                changesCountLabel.toolTip = "\(commit.filesChanged) \(commit.filesChanged == 1 ? "file" : "files") changed"
                changesCountLabel.isHidden = false
                bottomRowStack.setVisibilityPriority(.mustHold, for: changesCountLabel)
                dotLabel2.isHidden = false
                bottomRowStack.setVisibilityPriority(.mustHold, for: dotLabel2)
            } else {
                changesCountLabel.isHidden = true
                changesCountLabel.toolTip = nil
                bottomRowStack.setVisibilityPriority(.notVisible, for: changesCountLabel)
                dotLabel2.isHidden = true
                bottomRowStack.setVisibilityPriority(.notVisible, for: dotLabel2)
            }

            if commit.additions > 0 {
                additionsLabel.stringValue = "+\(commit.additions)"
                additionsLabel.isHidden = false
                bottomRowStack.setVisibilityPriority(.mustHold, for: additionsLabel)
            } else {
                additionsLabel.isHidden = true
                bottomRowStack.setVisibilityPriority(.notVisible, for: additionsLabel)
            }

            if commit.deletions > 0 {
                deletionsLabel.stringValue = "-\(commit.deletions)"
                deletionsLabel.isHidden = false
                bottomRowStack.setVisibilityPriority(.mustHold, for: deletionsLabel)
            } else {
                deletionsLabel.isHidden = true
                bottomRowStack.setVisibilityPriority(.notVisible, for: deletionsLabel)
            }

            infoButton.isHidden = false
            bottomRowStack.setVisibilityPriority(.mustHold, for: infoButton)
            infoButton.contentTintColor = Color(theme.gutterForeground).nsColor.withAlphaComponent(0.65)
        }
    }


    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter
    }()

    private static let relativeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static func formatRelativeDate(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 {
            return "just now"
        } else if seconds < 3600 {
            let mins = max(1, Int(seconds / 60))
            return "\(mins)m ago"
        } else if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return "\(hours)h ago"
        } else if seconds < 86400 * 30 {
            let days = Int(seconds / 86400)
            return "\(days)d ago"
        } else {
            return relativeDateFormatter.string(from: date)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let commit = currentCommit else { return nil }

        let menu = NSMenu(title: "Commit")

        let detailsItem = NSMenuItem(title: "View Commit Details...", action: #selector(showDetailsAction), keyEquivalent: "")
        detailsItem.target = self
        menu.addItem(detailsItem)

        menu.addItem(NSMenuItem.separator())

        let copyHashItem = NSMenuItem(title: "Copy Commit Hash (\(commit.shortHash))", action: #selector(copyHashAction), keyEquivalent: "")
        copyHashItem.target = self
        menu.addItem(copyHashItem)

        let copyMessageItem = NSMenuItem(title: "Copy Commit Message", action: #selector(copyMessageAction), keyEquivalent: "")
        copyMessageItem.target = self
        menu.addItem(copyMessageItem)

        return menu
    }

    @objc private func showDetailsAction() {
        guard let commit = currentCommit, let theme = currentTheme else { return }
        showDetailsPopover(for: commit, theme: theme)
    }

    @objc private func infoButtonClicked() {
        guard let commit = currentCommit, let theme = currentTheme else { return }
        showDetailsPopover(for: commit, theme: theme)
    }

    private func showDetailsPopover(for commit: GitCommit, theme: Theme) {
        Self.dismissActivePopover()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)

        let initialFiles = GitLogReader.shared.readCommitFiles(directory: currentDirectory, hash: commit.hash)

        let popoverView = CommitDetailPopoverView(
            commit: commit,
            theme: theme,
            directory: currentDirectory,
            files: initialFiles,
            onSelectFile: { [weak self, weak popover] file in
                popover?.close()
                if Self.activePopover === popover {
                    Self.activePopover = nil
                    Self.activePopoverAnchor = nil
                }
                guard let self = self, let commit = self.currentCommit else { return }
                if let onSelectCommitFile = self.onSelectCommitFileAction {
                    onSelectCommitFile(commit, file.path)
                } else {
                    self.onSelectCommitAction?(commit)
                }
            },
            onOpen: { [weak self] in
                guard let self = self, let commit = self.currentCommit else { return }
                self.onSelectCommitAction?(commit)
            },
            onClose: { [weak popover] in
                popover?.close()
                if Self.activePopover === popover {
                    Self.activePopover = nil
                    Self.activePopoverAnchor = nil
                }
            }
        )

        let hostingController = NSHostingController(rootView: popoverView)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            popover.contentSize = fitting
        }
        popover.contentViewController = hostingController
        Self.activePopover = popover
        Self.activePopoverAnchor = self

        // Anchor directly below the info button (i)
        let anchorView = infoButton.isHidden ? summaryLabel : infoButton
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    @objc private func copyHashAction() {
        guard let commit = currentCommit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.hash, forType: .string)
    }

    @objc private func copyMessageAction() {
        guard let commit = currentCommit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.summary, forType: .string)
    }
}

private extension Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}
