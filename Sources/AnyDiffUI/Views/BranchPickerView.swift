import SwiftUI
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

    private var filteredLocalBranches: [String] {
        if searchText.isEmpty { return localBranches }
        return localBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredRemoteBranches: [String] {
        if searchText.isEmpty { return remoteBranches }
        return remoteBranches.filter { $0.localizedCaseInsensitiveContains(searchText) }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if searchText.isEmpty {
                        comparisonModesSection
                        Divider()
                            .padding(.vertical, 4)
                    }

                    if !filteredLocalBranches.isEmpty {
                        localBranchesSection
                    }

                    if !filteredRemoteBranches.isEmpty {
                        if !filteredLocalBranches.isEmpty || searchText.isEmpty {
                            Divider()
                                .padding(.vertical, 4)
                        }
                        remoteBranchesSection
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 270)
        .padding(4)
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
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var comparisonModesSection: some View {
        Text("COMPARISON TARGET")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)

        branchRowButton(
            title: "Working Tree (Uncommitted)",
            subtitle: "staged + unstaged vs HEAD",
            icon: "clock.arrow.circlepath",
            isSelected: comparisonTarget == .workingTree
        ) {
            comparisonTarget = .workingTree
            onSelectTarget(.workingTree)
            isPresented = false
        }

        let commonBases = ["main", "master", "develop"].filter { localBranches.contains($0) && $0 != currentBranch }
        ForEach(commonBases, id: \.self) { base in
            branchRowButton(
                title: "Compare with \(base)",
                subtitle: "\(base)...\(currentBranch)",
                icon: "arrow.triangle.branch",
                isSelected: comparisonTarget == .baseBranch(base)
            ) {
                let target = ComparisonTarget.baseBranch(base)
                comparisonTarget = target
                onSelectTarget(target)
                isPresented = false
            }
        }
    }

    @ViewBuilder
    private var localBranchesSection: some View {
        Text("BRANCHES (\(filteredLocalBranches.count))")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)

        ForEach(filteredLocalBranches, id: \.self) { branch in
            let isCurrent = (branch == currentBranch)
            branchRowButton(
                title: branch,
                subtitle: isCurrent ? "Active checkout" : "Compare against \(branch)",
                icon: "arrow.triangle.branch",
                isSelected: isCurrent && comparisonTarget == .workingTree || comparisonTarget == .baseBranch(branch)
            ) {
                if isCurrent {
                    comparisonTarget = .workingTree
                    onSelectTarget(.workingTree)
                } else {
                    let target = ComparisonTarget.baseBranch(branch)
                    comparisonTarget = target
                    onSelectTarget(target)
                }
                isPresented = false
            }
        }
    }

    @ViewBuilder
    private var remoteBranchesSection: some View {
        Text("REMOTE BRANCHES (\(filteredRemoteBranches.count))")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 2)

        ForEach(filteredRemoteBranches, id: \.self) { branch in
            branchRowButton(
                title: branch,
                subtitle: "Compare against \(branch)",
                icon: "cloud",
                isSelected: comparisonTarget == .baseBranch(branch)
            ) {
                let target = ComparisonTarget.baseBranch(branch)
                comparisonTarget = target
                onSelectTarget(target)
                isPresented = false
            }
        }
    }

    private func branchRowButton(
        title: String,
        subtitle: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
