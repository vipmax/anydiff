import SwiftUI
import AppKit
import AnyDiffCore

/// High-performance virtualized file tree view backed by native AppKit NSTableView.
/// Provides smooth 120 FPS momentum scrolling, cell reuse, indentation, git status badges, and context menus.
public struct VirtualizedFileTreeView: NSViewRepresentable {
    public var items: [FileItem]
    public var expandedPaths: Set<String>
    public var gitStatusMap: [String: FileDiffStatus]
    public var openFilePaths: Set<String>
    public var theme: Theme
    @Binding public var selectedFilePath: String?
    public var onToggleExpand: (String) -> Void
    public var onOpenFile: (String) -> Void
    public var onOpenExternalIDE: ((String) -> Void)?
    public var onPreviewMarkdown: ((String) -> Void)?

    public init(
        items: [FileItem],
        expandedPaths: Set<String>,
        gitStatusMap: [String: FileDiffStatus],
        openFilePaths: Set<String>,
        theme: Theme,
        selectedFilePath: Binding<String?>,
        onToggleExpand: @escaping (String) -> Void,
        onOpenFile: @escaping (String) -> Void,
        onOpenExternalIDE: ((String) -> Void)? = nil,
        onPreviewMarkdown: ((String) -> Void)? = nil
    ) {
        self.items = items
        self.expandedPaths = expandedPaths
        self.gitStatusMap = gitStatusMap
        self.openFilePaths = openFilePaths
        self.theme = theme
        self._selectedFilePath = selectedFilePath
        self.onToggleExpand = onToggleExpand
        self.onOpenFile = onOpenFile
        self.onOpenExternalIDE = onOpenExternalIDE
        self.onPreviewMarkdown = onPreviewMarkdown
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
        scrollView.contentView.postsBoundsChangedNotifications = true

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let tableView = FileTreeTableView()
        tableView.treeCoordinator = context.coordinator
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.rowHeight = 24
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 1)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TreeColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.tableClicked(_:))

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = context.coordinator.tableView else { return }

        let itemsChanged = context.coordinator.cachedItems != items
        let expandedChanged = context.coordinator.cachedExpandedPaths != expandedPaths
        let gitStatusChanged = context.coordinator.cachedGitStatusMap != gitStatusMap
        let openPathsChanged = context.coordinator.cachedOpenFilePaths != openFilePaths
        let themeChanged = context.coordinator.cachedThemeId != theme.id

        if !context.coordinator.needsFullReload && !themeChanged && itemsChanged {
            let oldItems = context.coordinator.cachedItems
            let diff = items.difference(from: oldItems)

            var inserts = IndexSet()
            var removes = IndexSet()
            for change in diff {
                switch change {
                case .insert(let offset, _, _):
                    inserts.insert(offset)
                case .remove(let offset, _, _):
                    removes.insert(offset)
                }
            }

            // Update cached state before updating table so dataSource is consistent
            context.coordinator.cachedItems = items
            context.coordinator.cachedExpandedPaths = expandedPaths
            context.coordinator.cachedGitStatusMap = gitStatusMap
            context.coordinator.cachedOpenFilePaths = openFilePaths
            context.coordinator.cachedThemeId = theme.id

            if !inserts.isEmpty && removes.isEmpty {
                tableView.beginUpdates()
                tableView.insertRows(at: inserts, withAnimation: .slideDown)
                tableView.endUpdates()

                // Refresh parent folder row to update folder icon
                if let firstInsert = inserts.first, firstInsert > 0 {
                    let parentRow = firstInsert - 1
                    if parentRow < items.count,
                       let cell = tableView.view(atColumn: 0, row: parentRow, makeIfNecessary: false) as? FileTreeTableCellView {
                        cell.setExpanded(true)
                    }
                }
            } else if !removes.isEmpty && inserts.isEmpty {
                tableView.beginUpdates()
                tableView.removeRows(at: removes, withAnimation: .slideUp)
                tableView.endUpdates()

                // Update folder icons for remaining visible rows
                for row in 0..<items.count {
                    if items[row].isDirectory,
                       let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileTreeTableCellView {
                        cell.setExpanded(expandedPaths.contains(items[row].fullPath))
                    }
                }
            } else {
                tableView.reloadData()
            }

            if let treeTable = tableView as? FileTreeTableView, let window = treeTable.window {
                treeTable.updateHover(with: window.mouseLocationOutsideOfEventStream)
            }
        } else if itemsChanged || expandedChanged || gitStatusChanged || openPathsChanged || themeChanged || context.coordinator.needsFullReload {
            context.coordinator.cachedItems = items
            context.coordinator.cachedExpandedPaths = expandedPaths
            context.coordinator.cachedGitStatusMap = gitStatusMap
            context.coordinator.cachedOpenFilePaths = openFilePaths
            context.coordinator.cachedThemeId = theme.id
            context.coordinator.needsFullReload = false
            tableView.reloadData()
        }

        // Sync selection
        if let selectedPath = selectedFilePath,
           let index = items.firstIndex(where: { !$0.isDirectory && $0.relativePath == selectedPath }) {
            if tableView.selectedRow != index {
                context.coordinator.isSyncingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                context.coordinator.isSyncingSelection = false
            }
        } else if selectedFilePath == nil && tableView.selectedRow != -1 {
            context.coordinator.isSyncingSelection = true
            tableView.deselectAll(nil)
            context.coordinator.isSyncingSelection = false
        }
    }

    public final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: VirtualizedFileTreeView
        weak var tableView: NSTableView?
        var isSyncingSelection: Bool = false
        var cachedItems: [FileItem] = []
        var cachedExpandedPaths: Set<String> = []
        var cachedGitStatusMap: [String: FileDiffStatus] = [:]
        var cachedOpenFilePaths: Set<String> = []
        var cachedThemeId: String = ""
        var needsFullReload: Bool = true

        init(_ parent: VirtualizedFileTreeView) {
            self.parent = parent
            self.cachedItems = parent.items
            self.cachedExpandedPaths = parent.expandedPaths
            self.cachedGitStatusMap = parent.gitStatusMap
            self.cachedOpenFilePaths = parent.openFilePaths
            self.cachedThemeId = parent.theme.id
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            parent.items.count
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("FileTreeRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? FileTreeTableRowView
            if rowView == nil {
                rowView = FileTreeTableRowView()
                rowView?.identifier = identifier
            }
            rowView?.tableView = tableView as? FileTreeTableView
            rowView?.hoverColor = parent.theme.gutterForeground.withAlphaComponent(0.08)
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < parent.items.count else { return nil }
            let item = parent.items[row]
            let identifier = NSUserInterfaceItemIdentifier("FileTreeCellView")

            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileTreeTableCellView
            if cell == nil {
                cell = FileTreeTableCellView()
                cell?.identifier = identifier
            }

            let isExpanded = parent.expandedPaths.contains(item.fullPath)
            let isSelected = parent.selectedFilePath == item.relativePath
            let status = parent.gitStatusMap[item.relativePath]
            let isOpen = parent.openFilePaths.contains(item.relativePath)

            cell?.configure(
                item: item,
                isExpanded: isExpanded,
                isSelected: isSelected,
                status: status,
                isOpen: isOpen,
                theme: parent.theme
            )

            return cell
        }

        @objc func tableClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0 && row < parent.items.count else { return }
            let item = parent.items[row]
            if item.isDirectory {
                parent.onToggleExpand(item.fullPath)
            } else {
                parent.selectedFilePath = item.relativePath
                parent.onOpenFile(item.relativePath)
            }
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            guard let tableView = tableView else { return }
            let selectedRow = tableView.selectedRow
            guard selectedRow >= 0 && selectedRow < parent.items.count else { return }
            let item = parent.items[selectedRow]
            if !item.isDirectory && parent.selectedFilePath != item.relativePath {
                parent.selectedFilePath = item.relativePath
                parent.onOpenFile(item.relativePath)
            }
        }

        // MARK: - Context Menu Building

        func buildContextMenu(for item: FileItem) -> NSMenu {
            let menu = NSMenu(title: "File Context Menu")

            if !item.isDirectory {
                let openItem = NSMenuItem(title: "Open in AnyDiff", action: #selector(contextOpenInAnyDiff(_:)), keyEquivalent: "")
                openItem.target = self
                openItem.representedObject = item
                menu.addItem(openItem)

                let isMarkdown = item.name.hasSuffix(".md") || item.name.hasSuffix(".markdown") || item.name.hasSuffix(".mdx")
                if isMarkdown && parent.onPreviewMarkdown != nil {
                    let previewItem = NSMenuItem(title: "Preview Markdown", action: #selector(contextPreviewMarkdown(_:)), keyEquivalent: "")
                    previewItem.target = self
                    previewItem.representedObject = item
                    menu.addItem(previewItem)
                }

                if parent.onOpenExternalIDE != nil {
                    let externalItem = NSMenuItem(title: "Open in External IDE", action: #selector(contextOpenInExternalIDE(_:)), keyEquivalent: "")
                    externalItem.target = self
                    externalItem.representedObject = item
                    menu.addItem(externalItem)
                }

                menu.addItem(NSMenuItem.separator())
            }

            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(contextRevealInFinder(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = item
            menu.addItem(revealItem)

            let copyRelItem = NSMenuItem(title: "Copy Relative Path", action: #selector(contextCopyRelativePath(_:)), keyEquivalent: "")
            copyRelItem.target = self
            copyRelItem.representedObject = item
            menu.addItem(copyRelItem)

            let copyFullItem = NSMenuItem(title: "Copy Full Path", action: #selector(contextCopyFullPath(_:)), keyEquivalent: "")
            copyFullItem.target = self
            copyFullItem.representedObject = item
            menu.addItem(copyFullItem)

            return menu
        }

        @objc private func contextOpenInAnyDiff(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            parent.selectedFilePath = item.relativePath
            parent.onOpenFile(item.relativePath)
        }

        @objc private func contextPreviewMarkdown(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            parent.selectedFilePath = item.relativePath
            parent.onPreviewMarkdown?(item.relativePath)
        }

        @objc private func contextOpenInExternalIDE(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            parent.onOpenExternalIDE?(item.relativePath)
        }

        @objc private func contextRevealInFinder(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            let url = URL(fileURLWithPath: item.fullPath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        @objc private func contextCopyRelativePath(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            let path = item.relativePath.isEmpty ? item.name : item.relativePath
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }

        @objc private func contextCopyFullPath(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? FileItem else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.fullPath, forType: .string)
        }

        @objc func clipViewBoundsDidChange(_ notification: Notification) {
            guard let tableView = tableView as? FileTreeTableView, let window = tableView.window else { return }
            tableView.updateHover(with: window.mouseLocationOutsideOfEventStream)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - FileTreeTableView Subclass with Key Navigation & Context Menu

final class FileTreeTableView: NSTableView {
    weak var treeCoordinator: VirtualizedFileTreeView.Coordinator?
    var hoveredRow: Int = -1
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(with: event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(with: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    func updateHover(with windowLocation: NSPoint) {
        let point = convert(windowLocation, from: nil)
        let row = bounds.contains(point) ? row(at: point) : -1
        if row != hoveredRow {
            let oldRow = hoveredRow
            hoveredRow = row
            if oldRow >= 0 {
                rowView(atRow: oldRow, makeIfNecessary: false)?.needsDisplay = true
            }
            if row >= 0 {
                rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
        }
    }

    func clearHover() {
        if hoveredRow >= 0 {
            let oldRow = hoveredRow
            hoveredRow = -1
            rowView(atRow: oldRow, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, let coordinator = treeCoordinator, row < coordinator.parent.items.count else {
            return nil
        }
        let item = coordinator.parent.items[row]
        return coordinator.buildContextMenu(for: item)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return / Enter
            if selectedRow >= 0, let coordinator = treeCoordinator, selectedRow < coordinator.parent.items.count {
                let item = coordinator.parent.items[selectedRow]
                if item.isDirectory {
                    coordinator.parent.onToggleExpand(item.fullPath)
                } else {
                    coordinator.parent.onOpenFile(item.relativePath)
                }
                return
            }
        case 124: // Right Arrow
            if selectedRow >= 0, let coordinator = treeCoordinator, selectedRow < coordinator.parent.items.count {
                let item = coordinator.parent.items[selectedRow]
                if item.isDirectory && !coordinator.parent.expandedPaths.contains(item.fullPath) {
                    coordinator.parent.onToggleExpand(item.fullPath)
                    return
                }
            }
        case 123: // Left Arrow
            if selectedRow >= 0, let coordinator = treeCoordinator, selectedRow < coordinator.parent.items.count {
                let item = coordinator.parent.items[selectedRow]
                if item.isDirectory && coordinator.parent.expandedPaths.contains(item.fullPath) {
                    coordinator.parent.onToggleExpand(item.fullPath)
                    return
                }
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}

// MARK: - Row View with Hover and Rounded Selection

final class FileTreeTableRowView: NSTableRowView {
    weak var tableView: FileTreeTableView?
    var hoverColor: NSColor = NSColor.textColor.withAlphaComponent(0.06)

    override func prepareForReuse() {
        super.prepareForReuse()
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {
        if isSelected {
            let selectionRect = bounds.insetBy(dx: 4, dy: 1)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard let table = tableView ?? (superview as? FileTreeTableView) else { return }
        let myRow = table.row(for: self)
        if !isSelected && myRow == table.hoveredRow && myRow >= 0 {
            let hoverRect = bounds.insetBy(dx: 4, dy: 1)
            let path = NSBezierPath(roundedRect: hoverRect, xRadius: 4, yRadius: 4)
            hoverColor.setFill()
            path.fill()
        }
    }
}

// MARK: - High-Performance Recycled File Tree Cell View

final class FileTreeTableCellView: NSTableCellView {
    private let indentSpacer = NSView()
    private var indentWidthConstraint: NSLayoutConstraint!

    private let iconImageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    private let trailingStack = NSStackView()
    private let openIndicatorView = NSView()
    private let statusBadgeContainer = NSView()
    private let statusBadgeLabel = NSTextField(labelWithString: "")

    // MARK: - Static Cached Assets

    private static let folderFillImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }()

    private static let folderImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }()

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

        // 1. Indent Spacer
        indentSpacer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indentSpacer)
        indentWidthConstraint = indentSpacer.widthAnchor.constraint(equalToConstant: 0)

        // 2. File / Folder Icon
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)

        // 3. Name Label
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .regular)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        // 4. Open Indicator Dot
        openIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        openIndicatorView.wantsLayer = true
        openIndicatorView.layer?.cornerRadius = 2.5
        openIndicatorView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        openIndicatorView.toolTip = "Open in Editor"

        // 5. Status Badge Container & Label
        statusBadgeContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBadgeContainer.wantsLayer = true
        statusBadgeContainer.layer?.cornerRadius = 3
        statusBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBadgeLabel.font = .monospacedSystemFont(ofSize: 9.5, weight: .bold)
        statusBadgeLabel.alignment = .center
        statusBadgeContainer.addSubview(statusBadgeLabel)

        // 6. Trailing Stack
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 5
        trailingStack.addArrangedSubview(openIndicatorView)
        trailingStack.addArrangedSubview(statusBadgeContainer)
        addSubview(trailingStack)

        // Constraints
        NSLayoutConstraint.activate([
            indentSpacer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            indentSpacer.centerYAnchor.constraint(equalTo: centerYAnchor),
            indentSpacer.heightAnchor.constraint(equalToConstant: 1),
            indentWidthConstraint,

            iconImageView.leadingAnchor.constraint(equalTo: indentSpacer.trailingAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -6),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            openIndicatorView.widthAnchor.constraint(equalToConstant: 5),
            openIndicatorView.heightAnchor.constraint(equalToConstant: 5),

            statusBadgeLabel.leadingAnchor.constraint(equalTo: statusBadgeContainer.leadingAnchor, constant: 3.5),
            statusBadgeLabel.trailingAnchor.constraint(equalTo: statusBadgeContainer.trailingAnchor, constant: -3.5),
            statusBadgeLabel.topAnchor.constraint(equalTo: statusBadgeContainer.topAnchor, constant: 0.5),
            statusBadgeLabel.bottomAnchor.constraint(equalTo: statusBadgeContainer.bottomAnchor, constant: -0.5),
        ])
    }

    func setExpanded(_ isExpanded: Bool) {
        let targetImage = isExpanded ? Self.folderFillImage : Self.folderImage
        if iconImageView.image !== targetImage {
            let transition = CATransition()
            transition.duration = 0.15
            transition.type = .fade
            iconImageView.layer?.add(transition, forKey: "folderIconTransition")
            iconImageView.image = targetImage
        }
    }

    func configure(
        item: FileItem,
        isExpanded: Bool,
        isSelected: Bool,
        status: FileDiffStatus?,
        isOpen: Bool,
        theme: Theme
    ) {
        // Indentation
        indentWidthConstraint.constant = CGFloat(item.level * 16)

        // Icon
        if item.isDirectory {
            setExpanded(isExpanded)
            iconImageView.contentTintColor = NSColor.controlAccentColor.withAlphaComponent(0.85)
        } else {
            iconImageView.layer?.removeAnimation(forKey: "folderIconTransition")
            iconImageView.contentTintColor = nil
            iconImageView.image = FileIconProvider.shared.image(for: item.relativePath, pointSize: 12, weight: .regular)
        }

        // Name
        nameLabel.stringValue = item.name
        if item.level == 0 && item.isDirectory {
            nameLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .bold : .semibold)
            nameLabel.textColor = theme.foreground
        } else if isSelected {
            nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            nameLabel.textColor = theme.foreground
        } else {
            nameLabel.font = .systemFont(ofSize: 12, weight: .regular)
            if let status = status, !item.isDirectory {
                switch status {
                case .added: nameLabel.textColor = theme.diffAddedGutter
                case .modified, .renamed: nameLabel.textColor = theme.diffModifiedGutter
                case .deleted: nameLabel.textColor = theme.diffDeletedGutter
                case .copied: nameLabel.textColor = .systemBlue
                case .unmodified: nameLabel.textColor = theme.foreground
                }
            } else {
                nameLabel.textColor = theme.foreground
            }
        }

        // Open in Buffer Indicator
        openIndicatorView.isHidden = !(isOpen && !item.isDirectory)

        // Status Badge
        if let status = status, !item.isDirectory, status != .unmodified {
            let (letter, color): (String, NSColor) = {
                switch status {
                case .added: return ("A", theme.diffAddedGutter)
                case .modified: return ("M", theme.diffModifiedGutter)
                case .deleted: return ("D", theme.diffDeletedGutter)
                case .renamed: return ("R", theme.diffModifiedGutter)
                case .copied: return ("C", .systemBlue)
                case .unmodified: return ("", .clear)
                }
            }()

            if !letter.isEmpty {
                statusBadgeLabel.stringValue = letter
                statusBadgeLabel.textColor = color
                statusBadgeContainer.layer?.backgroundColor = color.withAlphaComponent(0.12).cgColor
                statusBadgeContainer.isHidden = false
            } else {
                statusBadgeContainer.isHidden = true
            }
        } else {
            statusBadgeContainer.isHidden = true
        }
    }
}
