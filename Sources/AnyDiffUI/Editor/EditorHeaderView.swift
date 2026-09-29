import SwiftUI
import AnyDiffCore

public struct EditorHeaderLeadingView: View {
    public let theme: Theme
    public let availableWidth: CGFloat
    public let title: String
    public let tooltip: String
    public let iconName: String
    public let changeCount: Int?
    public let badges: AnyView

    public init(
        theme: Theme,
        availableWidth: CGFloat = 600,
        title: String,
        tooltip: String = "",
        iconName: String,
        changeCount: Int? = nil,
        badges: AnyView = AnyView(EmptyView())
    ) {
        self.theme = theme
        self.availableWidth = availableWidth
        self.title = title
        self.tooltip = tooltip
        self.iconName = iconName
        self.changeCount = changeCount
        self.badges = badges
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 14, height: 14)
                .foregroundColor(Color(theme.gutterForeground))

            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(theme.foreground))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(tooltip)

            if let count = changeCount, availableWidth >= 420 {
                Text("\(count) \(count == 1 ? "change" : "changes")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(theme.gutterForeground))
                    .lineLimit(1)
            }

            badges
        }
        .lineLimit(1)
    }
}

public struct EditorHeaderActionsView: View {
    public let theme: Theme
    public let availableWidth: CGFloat
    public let hasCollapsedFiles: Bool
    public let diffLayoutMode: DiffLayoutMode
    public let isSearchActive: Bool
    public let totalAdds: Int
    public let totalDels: Int
    public let disableHunkNavigation: Bool
    public let onPreviousHunk: () -> Void
    public let onNextHunk: () -> Void
    public let onToggleCollapse: () -> Void
    public let onToggleLayout: () -> Void
    public let onToggleSearch: () -> Void

    public init(
        theme: Theme,
        availableWidth: CGFloat = 600,
        hasCollapsedFiles: Bool = false,
        diffLayoutMode: DiffLayoutMode = .unified,
        isSearchActive: Bool = false,
        totalAdds: Int = 0,
        totalDels: Int = 0,
        disableHunkNavigation: Bool = false,
        onPreviousHunk: @escaping () -> Void,
        onNextHunk: @escaping () -> Void,
        onToggleCollapse: @escaping () -> Void,
        onToggleLayout: @escaping () -> Void,
        onToggleSearch: @escaping () -> Void
    ) {
        self.theme = theme
        self.availableWidth = availableWidth
        self.hasCollapsedFiles = hasCollapsedFiles
        self.diffLayoutMode = diffLayoutMode
        self.isSearchActive = isSearchActive
        self.totalAdds = totalAdds
        self.totalDels = totalDels
        self.disableHunkNavigation = disableHunkNavigation
        self.onPreviousHunk = onPreviousHunk
        self.onNextHunk = onNextHunk
        self.onToggleCollapse = onToggleCollapse
        self.onToggleLayout = onToggleLayout
        self.onToggleSearch = onToggleSearch
    }

    public var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 1) {
                Button(action: onPreviousHunk) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .foregroundColor(disableHunkNavigation ? Color(theme.gutterForeground).opacity(0.35) : Color(theme.gutterForeground))
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .disabled(disableHunkNavigation)
                .help("Go to Previous Hunk (⇧⌘F8 / ⇧F7)")

                Button(action: onNextHunk) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .foregroundColor(disableHunkNavigation ? Color(theme.gutterForeground).opacity(0.35) : Color(theme.gutterForeground))
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .disabled(disableHunkNavigation)
                .help("Go to Next Hunk (⌘F8 / F7)")
            }

            Rectangle()
                .fill(Color(theme.gutterForeground).opacity(0.2))
                .frame(width: 1, height: 12)
                .padding(.horizontal, 3)

            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .foregroundColor(hasCollapsedFiles ? Color(theme.foreground) : Color(theme.gutterForeground))
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help(hasCollapsedFiles ? "Expand All Files in MultiBuffer" : "Collapse All Files in MultiBuffer")

            Button(action: onToggleLayout) {
                DiffLayoutToggleIcon(mode: diffLayoutMode)
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help(diffLayoutMode == .unified ? "Switch to Side-by-Side Diff (⌘D)" : "Switch to Unified Diff (⌘D)")

            if availableWidth >= 290 || isSearchActive {
                Button(action: onToggleSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(isSearchActive ? Color(theme.foreground) : Color(theme.gutterForeground))
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .help("Find in Project (Cmd+Shift+F)")
            }

            if availableWidth >= 360 && (totalAdds > 0 || totalDels > 0) {
                HStack(spacing: 5) {
                    if totalAdds > 0 {
                        Text("+\(totalAdds)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(theme.diffAddedGutter))
                            .lineLimit(1)
                    }
                    if totalDels > 0 {
                        Text("-\(totalDels)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(theme.diffDeletedGutter))
                            .lineLimit(1)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 6)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}
