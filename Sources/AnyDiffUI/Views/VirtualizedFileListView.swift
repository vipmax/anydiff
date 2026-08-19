import SwiftUI
import AppKit
import AnyDiffCore

public struct VirtualizedFileListView: NSViewRepresentable {
    public var files: [FileDiff]
    public var theme: Theme
    public var reviewManager: ReviewManager
    @Binding public var selectedFilePath: String?
    public var onSelectFile: (String) -> Void

    public init(
        files: [FileDiff],
        theme: Theme,
        reviewManager: ReviewManager,
        selectedFilePath: Binding<String?>,
        onSelectFile: @escaping (String) -> Void
    ) {
        self.files = files
        self.theme = theme
        self.reviewManager = reviewManager
        self._selectedFilePath = selectedFilePath
        self.onSelectFile = onSelectFile
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

        public func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = tableView else { return }
            let selectedRow = tableView.selectedRow
            if selectedRow >= 0 && selectedRow < parent.files.count {
                let path = parent.files[selectedRow].displayPath
                if parent.selectedFilePath != path {
                    parent.selectedFilePath = path
                    parent.onSelectFile(path)
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
            let selectionRect = bounds.insetBy(dx: 4, dy: 1)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent default background
    }
}

// MARK: - Pixel-Perfect Centered Status Badge View
final class StatusBadgeView: NSView {
    var text: String = "" {
        didSet { if oldValue != text { needsDisplay = true } }
    }
    var tintColor: NSColor = .systemBlue {
        didSet { if oldValue != tintColor { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgRect = bounds
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 3.5, yRadius: 3.5)
        tintColor.withAlphaComponent(0.16).setFill()
        path.fill()

        guard !text.isEmpty else { return }

        let font = NSFont.systemFont(ofSize: 9.5, weight: .black)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: tintColor
        ]

        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedText.size()

        // Exact optical cap-height centering
        let x = (bgRect.width - textSize.width) / 2.0
        let y = (bgRect.height + font.capHeight) / 2.0 - font.ascender
        attributedText.draw(at: NSPoint(x: x, y: y))
    }
}

// MARK: - High-Performance Recycled File Cell View
final class FileTableCellView: NSTableCellView {
    private let statusBadge = StatusBadgeView()
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

        // 1. Status Badge (A / M / D / R)
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBadge)

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
            statusBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            statusBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusBadge.widthAnchor.constraint(equalToConstant: 16),
            statusBadge.heightAnchor.constraint(equalToConstant: 16),

            textStack.leadingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: 8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: additionsLabel.leadingAnchor, constant: -4),

            deletionsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deletionsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            additionsLabel.trailingAnchor.constraint(equalTo: deletionsLabel.leadingAnchor, constant: -4),
            additionsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        file: FileDiff,
        theme: Theme
    ) {
        // Status Badge
        let symbol: String
        let color: NSColor
        switch file.status {
        case .added:
            symbol = "A"
            color = .systemGreen
        case .deleted:
            symbol = "D"
            color = .systemRed
        case .renamed:
            symbol = "R"
            color = .systemPurple
        default:
            symbol = "M"
            color = .systemBlue
        }
        statusBadge.text = symbol
        statusBadge.tintColor = color

        // File Path & Name
        let fileName = (file.displayPath as NSString).lastPathComponent
        nameLabel.stringValue = fileName
        nameLabel.textColor = .labelColor

        let dir = (file.displayPath as NSString).deletingLastPathComponent
        if !dir.isEmpty && dir != "." {
            dirLabel.stringValue = dir
            dirLabel.isHidden = false
        } else {
            dirLabel.stringValue = ""
            dirLabel.isHidden = true
        }

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
