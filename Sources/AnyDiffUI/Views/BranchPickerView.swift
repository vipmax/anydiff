import SwiftUI
import AppKit
import AnyDiffCore

public struct BranchPickerView: View {
    public var currentBranch: String
    public var localBranches: [String]
    public var remoteBranches: [String]
    public var currentPath: String
    public var worktrees: [GitWorktree]
    public var theme: Theme
    @Binding public var comparisonTarget: ComparisonTarget
    public var onSelectTarget: (ComparisonTarget) -> Void
    public var onSelectWorktree: ((GitWorktree) -> Void)?
    public var onCreateWorktree: ((_ branch: String, _ baseRef: String?, _ createBranch: Bool) async -> Result<String, GitWorktreeError>)?
    public var onRemoveWorktree: ((_ worktree: GitWorktree, _ force: Bool) async -> Result<Void, GitWorktreeError>)?

    @State private var isPresented: Bool = false
    @State private var searchText: String = ""
    @State private var isShowingNewWorktreeForm: Bool = false
    @State private var newWorktreeBranch: String = ""
    @State private var newWorktreeBase: String = ""
    @State private var createNewBranch: Bool = true
    @State private var isCreatingWorktree: Bool = false
    @State private var worktreeError: String? = nil

    public init(
        currentBranch: String,
        localBranches: [String],
        remoteBranches: [String] = [],
        currentPath: String = "",
        worktrees: [GitWorktree] = [],
        theme: Theme = .zedDark,
        comparisonTarget: Binding<ComparisonTarget>,
        onSelectTarget: @escaping (ComparisonTarget) -> Void,
        onSelectWorktree: ((GitWorktree) -> Void)? = nil,
        onCreateWorktree: ((_ branch: String, _ baseRef: String?, _ createBranch: Bool) async -> Result<String, GitWorktreeError>)? = nil,
        onRemoveWorktree: ((_ worktree: GitWorktree, _ force: Bool) async -> Result<Void, GitWorktreeError>)? = nil
    ) {
        self.currentBranch = currentBranch
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.currentPath = currentPath
        self.worktrees = worktrees
        self.theme = theme
        self._comparisonTarget = comparisonTarget
        self.onSelectTarget = onSelectTarget
        self.onSelectWorktree = onSelectWorktree
        self.onCreateWorktree = onCreateWorktree
        self.onRemoveWorktree = onRemoveWorktree
    }

    private var isInLinkedWorktree: Bool {
        guard !currentPath.isEmpty else { return false }
        let resolvedCurrent = URL(fileURLWithPath: currentPath).resolvingSymlinksInPath().path
        return worktrees.contains { !$0.isMain && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolvedCurrent }
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
        case .commit(let hash, _):
            return String(hash.prefix(7))
        }
    }

    public var body: some View {
        Button(action: { isPresented.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: isInLinkedWorktree ? "square.stack.3d.up" : "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(comparisonTarget == .workingTree ? .secondary : Color(theme.accentColor))

                Text(buttonLabelText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(ToolbarHoverButtonStyle())
        .help("Select Git Branch, Worktree, or Comparison Target")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
        .onChange(of: isPresented) { presented in
            if !presented {
                isShowingNewWorktreeForm = false
                worktreeError = nil
            } else if newWorktreeBase.isEmpty {
                newWorktreeBase = currentBranch
            }
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isShowingNewWorktreeForm {
                newWorktreeForm
            } else {
                searchField
                Divider()
                VirtualizedBranchTableView(
                    currentBranch: currentBranch,
                    localBranches: localBranches,
                    remoteBranches: remoteBranches,
                    currentPath: currentPath,
                    worktrees: worktrees,
                    theme: theme,
                    comparisonTarget: comparisonTarget,
                    searchText: searchText,
                    canCreateWorktree: onCreateWorktree != nil,
                    onSelectTarget: { target in
                        comparisonTarget = target
                        onSelectTarget(target)
                        DispatchQueue.main.async {
                            isPresented = false
                        }
                    },
                    onSelectWorktree: { wt in
                        onSelectWorktree?(wt)
                        DispatchQueue.main.async {
                            isPresented = false
                        }
                    },
                    onRemoveWorktree: { wt in
                        handleRemoveWorktree(wt)
                    },
                    onRequestCreateWorktree: {
                        worktreeError = nil
                        newWorktreeBranch = ""
                        newWorktreeBase = currentBranch
                        createNewBranch = true
                        isShowingNewWorktreeForm = true
                    }
                )
                .frame(width: 280, height: 300)

                if let worktreeError {
                    Text(worktreeError)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                }
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var newWorktreeForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: {
                    isShowingNewWorktreeForm = false
                    worktreeError = nil
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                Text("New Worktree")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            Divider()

            Toggle("Create new branch", isOn: $createNewBranch)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .padding(.horizontal, 4)

            if createNewBranch {
                VStack(alignment: .leading, spacing: 3) {
                    Text("BRANCH NAME")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    TextField("e.g. feat/my-feature", text: $newWorktreeBranch)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { submitCreateWorktree() }
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 3) {
                    Text("BASE BRANCH")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $newWorktreeBase) {
                        ForEach(localBranches, id: \.self) { branch in
                            Text(branch).tag(branch)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 4)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EXISTING BRANCH")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $newWorktreeBranch) {
                        ForEach(availableExistingBranches, id: \.self) { branch in
                            Text(branch).tag(branch)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        if newWorktreeBranch.isEmpty, let first = availableExistingBranches.first {
                            newWorktreeBranch = first
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            if let worktreeError {
                Text(worktreeError)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            } else {
                let previewSlug = newWorktreeBranch
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: " ", with: "-")
                let repoFolder = worktrees.first?.folderName ?? ((currentPath as NSString).lastPathComponent.isEmpty ? "repo" : (currentPath as NSString).lastPathComponent)
                Text("Location: ~/.anydiff/worktrees/\(repoFolder)/\(previewSlug.isEmpty ? "<branch>" : previewSlug)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isShowingNewWorktreeForm = false
                    worktreeError = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(isCreatingWorktree ? "Creating..." : "Create") {
                    submitCreateWorktree()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isCreatingWorktree || newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
        .frame(width: 280)
    }

    private var availableExistingBranches: [String] {
        let checkedOut = Set(worktrees.compactMap(\.branch))
        let candidates = localBranches.filter { !checkedOut.contains($0) }
        return candidates.isEmpty ? localBranches : candidates
    }

    private func submitCreateWorktree() {
        let trimmed = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let onCreateWorktree else { return }
        isCreatingWorktree = true
        worktreeError = nil
        let base = createNewBranch ? (newWorktreeBase.isEmpty ? nil : newWorktreeBase) : nil
        let create = createNewBranch
        Task {
            let result = await onCreateWorktree(trimmed, base, create)
            await MainActor.run {
                isCreatingWorktree = false
                switch result {
                case .success:
                    isShowingNewWorktreeForm = false
                    isPresented = false
                case .failure(let err):
                    worktreeError = err.localizedDescription
                }
            }
        }
    }

    private func handleRemoveWorktree(_ worktree: GitWorktree) {
        guard let onRemoveWorktree else { return }
        worktreeError = nil
        Task {
            let result = await onRemoveWorktree(worktree, false)
            if case .failure(let err) = result {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Remove Worktree “\(worktree.displayTitle)”?"
                    alert.informativeText = "\(err.localizedDescription)\n\nDo you want to force remove it? Uncommitted changes in that worktree will be lost."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Force Remove")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        Task {
                            let forceResult = await onRemoveWorktree(worktree, true)
                            if case .failure(let forceErr) = forceResult {
                                await MainActor.run {
                                    self.worktreeError = forceErr.localizedDescription
                                }
                            }
                        }
                    }
                }
            }
        }
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

enum BranchPickerAction: Equatable {
    case comparison(ComparisonTarget)
    case worktree(GitWorktree)
}

enum BranchPickerRow: Equatable {
    case header(title: String, showNewWorktreeButton: Bool = false)
    case item(
        title: String,
        subtitle: String,
        iconName: String,
        isSelected: Bool,
        action: BranchPickerAction
    )
}

// MARK: - Virtualized NSScrollView + NSTableView for Instant Smooth Scrolling

public struct VirtualizedBranchTableView: NSViewRepresentable {
    public var currentBranch: String
    public var localBranches: [String]
    public var remoteBranches: [String]
    public var currentPath: String
    public var worktrees: [GitWorktree]
    public var theme: Theme
    public var comparisonTarget: ComparisonTarget
    public var searchText: String
    public var canCreateWorktree: Bool
    public var onSelectTarget: (ComparisonTarget) -> Void
    public var onSelectWorktree: ((GitWorktree) -> Void)?
    public var onRemoveWorktree: ((GitWorktree) -> Void)?
    public var onRequestCreateWorktree: (() -> Void)?

    public init(
        currentBranch: String,
        localBranches: [String],
        remoteBranches: [String],
        currentPath: String = "",
        worktrees: [GitWorktree] = [],
        theme: Theme = .zedDark,
        comparisonTarget: ComparisonTarget,
        searchText: String,
        canCreateWorktree: Bool = false,
        onSelectTarget: @escaping (ComparisonTarget) -> Void,
        onSelectWorktree: ((GitWorktree) -> Void)? = nil,
        onRemoveWorktree: ((GitWorktree) -> Void)? = nil,
        onRequestCreateWorktree: (() -> Void)? = nil
    ) {
        self.currentBranch = currentBranch
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.currentPath = currentPath
        self.worktrees = worktrees
        self.theme = theme
        self.comparisonTarget = comparisonTarget
        self.searchText = searchText
        self.canCreateWorktree = canCreateWorktree
        self.onSelectTarget = onSelectTarget
        self.onSelectWorktree = onSelectWorktree
        self.onRemoveWorktree = onRemoveWorktree
        self.onRequestCreateWorktree = onRequestCreateWorktree
    }

    func computeRows() -> [BranchPickerRow] {
        var rows: [BranchPickerRow] = []

        let filteredLocal: [String]
        let filteredRemote: [String]
        let filteredWorktrees: [GitWorktree]

        if searchText.isEmpty {
            filteredLocal = localBranches
            filteredRemote = remoteBranches
            filteredWorktrees = worktrees
        } else {
            filteredLocal = localBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
            filteredRemote = remoteBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
            filteredWorktrees = worktrees.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
            }
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
                action: .comparison(.workingTree)
            ))

            for base in commonBases {
                rows.append(.item(
                    title: "Compare with \(base)",
                    subtitle: "\(base)...\(currentBranch)",
                    iconName: "arrow.triangle.branch",
                    isSelected: comparisonTarget == .baseBranch(base),
                    action: .comparison(.baseBranch(base))
                ))
            }
        }

        // 2. Worktrees Section
        let showExistingWorktrees = worktrees.count > 1 || (!searchText.isEmpty && !filteredWorktrees.isEmpty)
        let showHeaderOnlyForCreate = canCreateWorktree && searchText.isEmpty
        if showExistingWorktrees || showHeaderOnlyForCreate {
            let resolvedCurrent = currentPath.isEmpty ? "" : URL(fileURLWithPath: currentPath).resolvingSymlinksInPath().path
            let headerTitle = showExistingWorktrees ? "WORKTREES (\(filteredWorktrees.count))" : "WORKTREES"
            rows.append(.header(title: headerTitle, showNewWorktreeButton: canCreateWorktree))
            if showExistingWorktrees {
                for wt in filteredWorktrees {
                    let resolvedWt = URL(fileURLWithPath: wt.path).resolvingSymlinksInPath().path
                    let isCurrent = !resolvedCurrent.isEmpty && resolvedWt == resolvedCurrent
                    let title = wt.isMain ? "\(wt.displayTitle) (main)" : wt.displayTitle
                    let subtitle = (wt.path as NSString).abbreviatingWithTildeInPath
                    rows.append(.item(
                        title: title,
                        subtitle: subtitle,
                        iconName: wt.isMain ? "folder" : "square.stack.3d.up",
                        isSelected: isCurrent,
                        action: .worktree(wt)
                    ))
                }
            }
        }

        // 3. Local Branches Section
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
                    action: .comparison(target)
                ))
            }
        }

        // 4. Remote Branches Section
        if !filteredRemote.isEmpty {
            rows.append(.header(title: "REMOTE BRANCHES (\(filteredRemote.count))"))
            for branch in filteredRemote {
                let isSelected = (comparisonTarget == .baseBranch(branch))
                rows.append(.item(
                    title: branch,
                    subtitle: "Compare against \(branch)",
                    iconName: "cloud",
                    isSelected: isSelected,
                    action: .comparison(.baseBranch(branch))
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
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }

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
        var cachedThemeId: String = ""

        init(_ parent: VirtualizedBranchTableView) {
            self.parent = parent
            self.rows = parent.computeRows()
            self.cachedThemeId = parent.theme.id
        }

        func update(parent: VirtualizedBranchTableView) {
            self.parent = parent
            let newRows = parent.computeRows()
            if self.rows != newRows || self.cachedThemeId != parent.theme.id {
                self.rows = newRows
                self.cachedThemeId = parent.theme.id
                tableView?.hoveredRow = nil
                tableView?.reloadData()
            }
        }

        @objc func onRowClicked() {
            guard let tableView = tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0 && row < rows.count else { return }
            if case .item(_, _, _, _, let action) = rows[row] {
                switch action {
                case .comparison(let target):
                    parent.onSelectTarget(target)
                case .worktree(let worktree):
                    parent.onSelectWorktree?(worktree)
                }
            }
        }

        func contextMenu(forRow row: Int) -> NSMenu? {
            guard row >= 0 && row < rows.count,
                  case .item(_, _, _, _, .worktree(let worktree)) = rows[row] else {
                return nil
            }
            let menu = NSMenu()
            let switchItem = NSMenuItem(title: "Switch to Worktree", action: #selector(onContextSwitchWorktree(_:)), keyEquivalent: "")
            switchItem.target = self
            switchItem.representedObject = worktree
            menu.addItem(switchItem)

            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(onContextRevealWorktree(_:)), keyEquivalent: "")
            revealItem.target = self
            revealItem.representedObject = worktree
            menu.addItem(revealItem)

            if !worktree.isMain, parent.onRemoveWorktree != nil {
                menu.addItem(.separator())
                let removeItem = NSMenuItem(title: "Remove Worktree...", action: #selector(onContextRemoveWorktree(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = worktree
                menu.addItem(removeItem)
            }
            return menu
        }

        @objc private func onContextSwitchWorktree(_ sender: NSMenuItem) {
            guard let wt = sender.representedObject as? GitWorktree else { return }
            parent.onSelectWorktree?(wt)
        }

        @objc private func onContextRevealWorktree(_ sender: NSMenuItem) {
            guard let wt = sender.representedObject as? GitWorktree else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt.path)])
        }

        @objc private func onContextRemoveWorktree(_ sender: NSMenuItem) {
            guard let wt = sender.representedObject as? GitWorktree else { return }
            parent.onRemoveWorktree?(wt)
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
            if row >= 0 && row < rows.count, case .item(_, _, _, let isSelected, _) = rows[row] {
                rowView?.isRowSelected = isSelected
            } else {
                rowView?.isRowSelected = false
            }
            rowView?.selectionColor = parent.theme.accentColor.withAlphaComponent(0.16)
            return rowView
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < rows.count else { return nil }
            let rowData = rows[row]

            switch rowData {
            case .header(let title, let showNewWorktreeButton):
                let identifier = NSUserInterfaceItemIdentifier("BranchHeaderCellView")
                var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BranchHeaderCellView
                if cell == nil {
                    cell = BranchHeaderCellView()
                    cell?.identifier = identifier
                }
                cell?.configure(
                    title: title,
                    actionTitle: showNewWorktreeButton ? "New" : nil,
                    accentColor: parent.theme.accentColor,
                    onAction: showNewWorktreeButton ? { [weak self] in
                        self?.parent.onRequestCreateWorktree?()
                    } : nil
                )
                return cell

            case .item(let title, let subtitle, let iconName, let isSelected, _):
                let identifier = NSUserInterfaceItemIdentifier("BranchItemCellView")
                var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? BranchItemCellView
                if cell == nil {
                    cell = BranchItemCellView()
                    cell?.identifier = identifier
                }
                cell?.configure(
                    title: title,
                    subtitle: subtitle,
                    iconName: iconName,
                    isSelected: isSelected,
                    accentColor: parent.theme.accentColor
                )
                return cell
            }
        }
    }
}

// MARK: - Centralized Hover-Tracking Table View

final class BranchTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?

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

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point)
        guard r >= 0 else { return nil }
        return contextMenuProvider?(r)
    }
}

// MARK: - Custom Table Row View with Centralized Hover & Selection Drawing

final class BranchTableRowView: NSTableRowView {
    var rowIndex: Int = -1
    var isRowSelected: Bool = false
    var selectionColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.16)

    override func drawBackground(in dirtyRect: NSRect) {
        if isRowSelected {
            let selectionRect = bounds.insetBy(dx: 4, dy: 1)
            let path = NSBezierPath(roundedRect: selectionRect, xRadius: 5, yRadius: 5)
            selectionColor.setFill()
            path.fill()
        } else if let tv = superview as? BranchTableView ?? (superview?.superview as? BranchTableView),
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
    private let actionButton = NSButton()
    private var onAction: (() -> Void)?

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

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isBordered = false
        actionButton.bezelStyle = .inline
        actionButton.font = .systemFont(ofSize: 10, weight: .medium)
        actionButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Worktree")
        actionButton.imagePosition = .imageLeading
        actionButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        actionButton.target = self
        actionButton.action = #selector(onActionTapped)
        actionButton.isHidden = true
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -6),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func onActionTapped() {
        onAction?()
    }

    func configure(
        title: String,
        actionTitle: String? = nil,
        accentColor: NSColor = .controlAccentColor,
        onAction: (() -> Void)? = nil
    ) {
        titleLabel.stringValue = title
        self.onAction = onAction
        if let actionTitle, !actionTitle.isEmpty, onAction != nil {
            actionButton.title = actionTitle
            actionButton.contentTintColor = accentColor
            actionButton.attributedTitle = NSAttributedString(
                string: actionTitle,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: accentColor
                ]
            )
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
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

    func configure(title: String, subtitle: String, iconName: String, isSelected: Bool, accentColor: NSColor) {
        iconView.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
        iconView.contentTintColor = isSelected ? accentColor : .secondaryLabelColor

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)

        subtitleLabel.stringValue = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty

        checkmarkView.contentTintColor = accentColor
        checkmarkView.isHidden = !isSelected
    }
}
