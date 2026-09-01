import SwiftUI
import AppKit
import AnyDiffCore

public struct VirtualizedFileListView: NSViewRepresentable {
    public var files: [FileDiff]
    public var theme: Theme
    public var reviewManager: ReviewManager
    @Binding public var selectedFilePath: String?

    public init(
        files: [FileDiff],
        theme: Theme,
        reviewManager: ReviewManager,
        selectedFilePath: Binding<String?>
    ) {
        self.files = files
        self.theme = theme
        self.reviewManager = reviewManager
        self._selectedFilePath = selectedFilePath
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
        tableView.rowHeight = 36
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
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

        let filesChanged = context.coordinator.cachedFiles != files
        let themeChanged = context.coordinator.cachedThemeId != theme.id
        let reviewedChanged = context.coordinator.cachedReviewedSet != reviewManager.reviewedFiles

        if filesChanged || themeChanged || reviewedChanged || context.coordinator.needsFullReload {
            context.coordinator.cachedFiles = files
            context.coordinator.cachedThemeId = theme.id
            context.coordinator.cachedReviewedSet = reviewManager.reviewedFiles
            context.coordinator.needsFullReload = false
            tableView.reloadData()
        }

        // Sync selection
        if let selectedPath = selectedFilePath,
           let index = files.firstIndex(where: { $0.displayPath == selectedPath }) {
            if tableView.selectedRow != index {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        } else if selectedFilePath == nil && tableView.selectedRow != -1 {
            tableView.deselectAll(nil)
        }
    }

    public final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: VirtualizedFileListView
        weak var tableView: NSTableView?
        var cachedFiles: [FileDiff] = []
        var cachedThemeId: String = ""
        var cachedReviewedSet: Set<String> = []
        var needsFullReload: Bool = true

        init(_ parent: VirtualizedFileListView) {
            self.parent = parent
            self.cachedFiles = parent.files
            self.cachedThemeId = parent.theme.id
            self.cachedReviewedSet = parent.reviewManager.reviewedFiles
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            parent.files.count
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("FileRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? CustomTableRowView
            if rowView == nil {
                rowView = CustomTableRowView()
                rowView?.identifier = identifier
            }
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < parent.files.count else { return nil }
            let file = parent.files[row]
            let identifier = NSUserInterfaceItemIdentifier("FileCellView")

            var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileTableCellView
            if cell == nil {
                cell = FileTableCellView()
                cell?.identifier = identifier
            }

            cell?.configure(
                file: file,
                theme: parent.theme
            )

            return cell
        }

        @objc func tableClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0 && row < parent.files.count else { return }
            let path = parent.files[row].displayPath
            parent.selectedFilePath = path
            NotificationCenter.default.post(name: .focusFileInEditor, object: path)
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = tableView else { return }
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0 && selectedRow < parent.files.count {
                let path = parent.files[selectedRow].displayPath
                if parent.selectedFilePath != path {
                    parent.selectedFilePath = path
                    NotificationCenter.default.post(name: .focusFileInEditor, object: path)
                }
            }
        }
    }
}

// MARK: - Custom Table Row View with rounded selection & hover
final class CustomTableRowView: NSTableRowView {
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
            let selectionRect = bounds.insetBy(dx: 12, dy: 3)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent default background
    }
}

// MARK: - High-Performance Recycled File Cell View
final class FileTableCellView: NSTableCellView {
    private let iconImageView = NSImageView()
    private let textStack = NSStackView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dirLabel = NSTextField(labelWithString: "")
    private let additionsLabel = NSTextField(labelWithString: "")
    private let deletionsLabel = NSTextField(labelWithString: "")

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

        // 1. File Type / Language Icon (replaces old modifier badge)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        // 2. File Name & Directory Labels in Stack
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        dirLabel.font = .systemFont(ofSize: 10, weight: .regular)
        dirLabel.textColor = .secondaryLabelColor
        dirLabel.lineBreakMode = .byTruncatingMiddle
        dirLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dirLabel.translatesAutoresizingMaskIntoConstraints = false

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(dirLabel)
        addSubview(textStack)

        // 3. Diff Stats Labels (+ / -)
        additionsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        additionsLabel.textColor = NSColor.systemGreen
        additionsLabel.alignment = .right
        additionsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(additionsLabel)

        deletionsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        deletionsLabel.textColor = NSColor.systemRed
        deletionsLabel.alignment = .right
        deletionsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deletionsLabel)

        // Layout Constraints
        NSLayoutConstraint.activate([
            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 16),
            iconImageView.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: additionsLabel.leadingAnchor, constant: -4),

            deletionsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            deletionsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            additionsLabel.trailingAnchor.constraint(equalTo: deletionsLabel.leadingAnchor, constant: -4),
            additionsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        file: FileDiff,
        theme: Theme
    ) {
        // File Icon
        iconImageView.image = FileIconProvider.shared.image(for: file.displayPath, pointSize: 14, weight: .medium)

        // File Path & Name with Status-Based Color from Theme (Added, Deleted, Renamed)
        if file.status == .renamed {
            let oldName = (file.oldPath as NSString).lastPathComponent
            let newName = (file.newPath as NSString).lastPathComponent
            if oldName != newName {
                nameLabel.stringValue = "\(oldName) → \(newName)"
            } else {
                nameLabel.stringValue = newName
            }
            nameLabel.textColor = theme.diffModifiedGutter

            let oldDir = (file.oldPath as NSString).deletingLastPathComponent
            let newDir = (file.newPath as NSString).deletingLastPathComponent
            if oldDir != newDir && (!oldDir.isEmpty || !newDir.isEmpty) {
                let displayOldDir = oldDir.isEmpty ? "." : oldDir
                let displayNewDir = newDir.isEmpty ? "." : newDir
                dirLabel.stringValue = "\(displayOldDir) → \(displayNewDir)"
                dirLabel.textColor = theme.gutterForeground
                dirLabel.isHidden = false
            } else if !newDir.isEmpty && newDir != "." {
                dirLabel.stringValue = newDir
                dirLabel.textColor = theme.gutterForeground
                dirLabel.isHidden = false
            } else {
                dirLabel.stringValue = ""
                dirLabel.isHidden = true
            }
        } else {
            let fileName = (file.displayPath as NSString).lastPathComponent
            nameLabel.stringValue = fileName

            switch file.status {
            case .added:
                nameLabel.textColor = theme.diffAddedGutter
            case .deleted:
                nameLabel.textColor = theme.diffDeletedGutter
            case .renamed:
                nameLabel.textColor = theme.diffModifiedGutter
            default:
                nameLabel.textColor = theme.foreground
            }

            let dir = (file.displayPath as NSString).deletingLastPathComponent
            if !dir.isEmpty && dir != "." {
                dirLabel.stringValue = dir
                dirLabel.textColor = theme.gutterForeground
                dirLabel.isHidden = false
            } else {
                dirLabel.stringValue = ""
                dirLabel.isHidden = true
            }
        }

        // Stats matching active theme
        additionsLabel.textColor = theme.diffAddedGutter
        deletionsLabel.textColor = theme.diffDeletedGutter

        // Stats
        if file.additions > 0 {
            additionsLabel.stringValue = "+\(file.additions)"
            additionsLabel.isHidden = false
        } else {
            additionsLabel.stringValue = ""
            additionsLabel.isHidden = true
        }

        if file.deletions > 0 {
            deletionsLabel.stringValue = "-\(file.deletions)"
            deletionsLabel.isHidden = false
        } else {
            deletionsLabel.stringValue = ""
            deletionsLabel.isHidden = true
        }
    }
}
