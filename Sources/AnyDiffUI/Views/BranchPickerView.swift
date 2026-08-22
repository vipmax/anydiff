import SwiftUI
import AppKit
import AnyDiffCore

public struct BranchPickerView: View {
    public var currentBranch: String
    public var localBranches: [String]
    public var remoteBranches: [String]
    @Binding public var comparisonTarget: ComparisonTarget
    public var onSelectTarget: (ComparisonTarget) -> Void

    @State private var isPresented: Bool = false
    @State private var searchText: String = ""

    public init(
        currentBranch: String,
        localBranches: [String],
        remoteBranches: [String] = [],
        comparisonTarget: Binding<ComparisonTarget>,
        onSelectTarget: @escaping (ComparisonTarget) -> Void
    ) {
        self.currentBranch = currentBranch
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self._comparisonTarget = comparisonTarget
        self.onSelectTarget = onSelectTarget
    }

    private var buttonLabelText: String {
        if currentBranch.isEmpty { return "Branch" }
        switch comparisonTarget {
        case .workingTree:
            return currentBranch
        case .baseBranch(let base):
            return "\(currentBranch) → \(base)"
        case .directBranch(let branch):
            return "\(currentBranch) vs \(branch)"
        case .remote(let ref):
            return ref.displayTitle
        }
    }

    public var body: some View {
        Button(action: { isPresented.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(comparisonTarget == .workingTree ? .secondary : .accentColor)

                Text(buttonLabelText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help("Select Git Branch / Comparison Target")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            Divider()
            VirtualizedBranchTableView(
                currentBranch: currentBranch,
                localBranches: localBranches,
                remoteBranches: remoteBranches,
                comparisonTarget: comparisonTarget,
                searchText: searchText,
                onSelectTarget: { target in
                    comparisonTarget = target
                    onSelectTarget(target)
                    DispatchQueue.main.async {
                        isPresented = false
                    }
                }
            )
            .frame(width: 270, height: 280)
        }
        .padding(6)
    }

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            TextField("Filter branches...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.06))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 0.8)
        )
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

// MARK: - Row Data Model

enum BranchPickerRow: Equatable {
    case header(title: String)
    case item(
        title: String,
        subtitle: String,
        iconName: String,
        isSelected: Bool,
        target: ComparisonTarget
    )
}

// MARK: - Virtualized NSScrollView + NSTableView for Instant Smooth Scrolling

public struct VirtualizedBranchTableView: NSViewRepresentable {
    public var currentBranch: String
    public var localBranches: [String]
    public var remoteBranches: [String]
    public var comparisonTarget: ComparisonTarget
    public var searchText: String
    public var onSelectTarget: (ComparisonTarget) -> Void

    public init(
        currentBranch: String,
        localBranches: [String],
        remoteBranches: [String],
        comparisonTarget: ComparisonTarget,
        searchText: String,
        onSelectTarget: @escaping (ComparisonTarget) -> Void
    ) {
        self.currentBranch = currentBranch
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.comparisonTarget = comparisonTarget
        self.searchText = searchText
        self.onSelectTarget = onSelectTarget
    }

    func computeRows() -> [BranchPickerRow] {
        var rows: [BranchPickerRow] = []

        let filteredLocal: [String]
        let filteredRemote: [String]

        if searchText.isEmpty {
            filteredLocal = localBranches
            filteredRemote = remoteBranches
        } else {
            filteredLocal = localBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
            filteredRemote = remoteBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }

        let commonBases = ["main", "master", "develop"].filter { localBranches.contains($0) && $0 != currentBranch }

        // 1. Comparison Modes Section
        if searchText.isEmpty {
            rows.append(.header(title: "COMPARISON TARGET"))
            rows.append(.item(
                title: "Working Tree (Uncommitted)",
                subtitle: "staged + unstaged vs HEAD",
                iconName: "clock.arrow.circlepath",
                isSelected: comparisonTarget == .workingTree,
                target: .workingTree
            ))

            for base in commonBases {
                rows.append(.item(
                    title: "Compare with \(base)",
                    subtitle: "\(base)...\(currentBranch)",
                    iconName: "arrow.triangle.branch",
                    isSelected: comparisonTarget == .baseBranch(base),
                    target: .baseBranch(base)
                ))
            }
        }

        // 2. Local Branches Section
        if !filteredLocal.isEmpty {
            rows.append(.header(title: "BRANCHES (\(filteredLocal.count))"))
            for branch in filteredLocal {
                let isCurrent = (branch == currentBranch)
                let isSelected: Bool
                if searchText.isEmpty {
                    if isCurrent || commonBases.contains(branch) {
                        isSelected = false
                    } else {
                        isSelected = (comparisonTarget == .baseBranch(branch))
                    }
                } else {
                    if isCurrent {
                        isSelected = (comparisonTarget == .workingTree)
                    } else {
                        isSelected = (comparisonTarget == .baseBranch(branch))
                    }
                }

                let target = isCurrent ? .workingTree : ComparisonTarget.baseBranch(branch)
                rows.append(.item(
                    title: branch,
                    subtitle: isCurrent ? "Active checkout" : "Compare against \(branch)",
                    iconName: "arrow.triangle.branch",
                    isSelected: isSelected,
                    target: target
                ))
            }
        }

        // 3. Remote Branches Section
        if !filteredRemote.isEmpty {
            rows.append(.header(title: "REMOTE BRANCHES (\(filteredRemote.count))"))
            for branch in filteredRemote {
                let isSelected = (comparisonTarget == .baseBranch(branch))
                rows.append(.item(
                    title: branch,
                    subtitle: "Compare against \(branch)",
                    iconName: "cloud",
                    isSelected: isSelected,
                    target: .baseBranch(branch)
                ))
            }
        }

        return rows
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

        let tableView = BranchTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("BranchColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.onRowClicked)

        context.coordinator.tableView = tableView
        scrollView.documentView = tableView

        context.coordinator.update(parent: self)
        return scrollView
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.update(parent: self)
    }

    public final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: VirtualizedBranchTableView
        weak var tableView: BranchTableView?
        var rows: [BranchPickerRow] = []

        init(_ parent: VirtualizedBranchTableView) {
            self.parent = parent
            self.rows = parent.computeRows()
        }

        func update(parent: VirtualizedBranchTableView) {
            self.parent = parent
            let newRows = parent.computeRows()
            if self.rows != newRows {
                self.rows = newRows
                tableView?.hoveredRow = nil
                tableView?.reloadData()
            }
        }

        @objc func onRowClicked() {
            guard let tableView = tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0 && row < rows.count else { return }
            if case .item(_, _, _, _, let target) = rows[row] {
                parent.onSelectTarget(target)
            }
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0 && row < rows.count else { return 32 }
            switch rows[row] {
            case .header:
                return 22
            case .item:
                return 34
            }
        }

        public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            guard row >= 0 && row < rows.count else { return false }
            switch rows[row] {
            case .header:
                return false
            case .item:
                return true
            }
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("BranchTableRowView")
            var rowView = tableView.makeView(withIdentifier: identifier, owner: self) as? BranchTableRowView
            if rowView == nil {
                rowView = BranchTableRowView()
                rowView?.identifier = identifier
            }
            rowView?.rowIndex = row
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < rows.count else { return nil }
            let rowData = rows[row]

            switch rowData {
            case .header(let title):
                let identifier = NSUserInterfaceItemIdentifier("BranchHeaderCellView")
                var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BranchHeaderCellView
                if cell == nil {
                    cell = BranchHeaderCellView()
                    cell?.identifier = identifier
                }
                cell?.configure(title: title)
                return cell

            case .item(let title, let subtitle, let iconName, let isSelected, _):
                let identifier = NSUserInterfaceItemIdentifier("BranchItemCellView")
                var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BranchItemCellView
                if cell == nil {
                    cell = BranchItemCellView()
                    cell?.identifier = identifier
                }
                cell?.configure(title: title, subtitle: subtitle, iconName: iconName, isSelected: isSelected)
                return cell
            }
        }
    }
}

// MARK: - Centralized Hover-Tracking Table View

final class BranchTableView: NSTableView {
    var hoveredRow: Int? = nil {
        didSet {
            if oldValue != hoveredRow {
                if let old = oldValue, old >= 0 && old < numberOfRows {
                    rowView(atRow: old, makeIfNecessary: false)?.needsDisplay = true
                }
                if let new = hoveredRow, new >= 0 && new < numberOfRows {
                    rowView(atRow: new, makeIfNecessary: false)?.needsDisplay = true
                }
            }
        }
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point)
        if r >= 0 && delegate?.tableView?(self, shouldSelectRow: r) == true {
            hoveredRow = r
        } else {
            hoveredRow = nil
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Custom Table Row View with Centralized Hover Drawing

final class BranchTableRowView: NSTableRowView {
    var rowIndex: Int = -1

    override func drawBackground(in dirtyRect: NSRect) {
        if let tv = superview as? BranchTableView ?? (superview?.superview as? BranchTableView),
           tv.hoveredRow == rowIndex {
            let hoverRect = bounds.insetBy(dx: 4, dy: 1)
            let path = NSBezierPath(roundedRect: hoverRect, xRadius: 5, yRadius: 5)
            NSColor.textColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
    }
}

// MARK: - Header Cell View

final class BranchHeaderCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        titleLabel.font = .systemFont(ofSize: 9, weight: .bold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    func configure(title: String) {
        titleLabel.stringValue = title
    }
}

// MARK: - Branch Item Cell View

final class BranchItemCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let checkmarkView = NSImageView()

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

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        checkmarkView.translatesAutoresizingMaskIntoConstraints = false
        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkmarkView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        checkmarkView.contentTintColor = .controlAccentColor
        addSubview(checkmarkView)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmarkView.leadingAnchor, constant: -4),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 0),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: checkmarkView.leadingAnchor, constant: -4),

            checkmarkView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            checkmarkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkmarkView.widthAnchor.constraint(equalToConstant: 12),
            checkmarkView.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    func configure(title: String, subtitle: String, iconName: String, isSelected: Bool) {
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)

        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty

        checkmarkView.isHidden = !isSelected
    }
}
