import SwiftUI
import AnyDiffCore

/// Shared 3-column `NavigationSplitView` + window toolbar chrome used by `MainWindowView`
/// and layout tests.
public struct MainWindowSplitShell<
    Left: View,
    Center: View,
    Right: View,
    NavItems: View,
    TrailingItems: View
>: View {
    @Binding private var columnVisibility: NavigationSplitViewVisibility
    @ObservedObject private var panelLayout: PanelLayoutManager
    private let theme: Theme
    private let left: () -> Left
    private let center: () -> Center
    private let right: () -> Right
    private let navItems: () -> NavItems
    private let trailingItems: () -> TrailingItems

    public init(
        columnVisibility: Binding<NavigationSplitViewVisibility>,
        panelLayout: PanelLayoutManager,
        theme: Theme,
        @ViewBuilder left: @escaping () -> Left,
        @ViewBuilder center: @escaping () -> Center,
        @ViewBuilder right: @escaping () -> Right,
        @ViewBuilder navItems: @escaping () -> NavItems,
        @ViewBuilder trailingItems: @escaping () -> TrailingItems
    ) {
        self._columnVisibility = columnVisibility
        self.panelLayout = panelLayout
        self.theme = theme
        self.left = left
        self.center = center
        self.right = right
        self.navItems = navItems
        self.trailingItems = trailingItems
    }

    public var body: some View {
        let colorScheme: ColorScheme = theme.isDark ? .dark : .light
        NavigationSplitView(columnVisibility: $columnVisibility) {
            left()
                .navigationSplitViewColumnWidth(
                    min: panelLayout.minWidth(for: .left),
                    ideal: panelLayout.idealWidth(for: .left),
                    max: panelLayout.maxWidth(for: .left)
                )
                .toolbarBackground(.hidden, for: .windowToolbar)
                .toolbarColorScheme(colorScheme, for: .windowToolbar)
        } content: {
            center()
                .navigationSplitViewColumnWidth(
                    min: panelLayout.minWidth(for: .center),
                    ideal: panelLayout.idealWidth(for: .center),
                    max: panelLayout.maxWidth(for: .center)
                )
                .toolbarBackground(.hidden, for: .windowToolbar)
                .toolbarColorScheme(colorScheme, for: .windowToolbar)
                .toolbar {
                    ToolbarItem(id: "mainWindowToolbarNav", placement: .navigation) {
                        navItems()
                    }
                    ToolbarItem(id: "mainWindowToolbarSpacer", placement: .automatic) {
                        Spacer()
                    }
                    ToolbarItem(id: "mainWindowToolbarTrailing", placement: .primaryAction) {
                        trailingItems()
                    }
                }
        } detail: {
            right()
                .navigationSplitViewColumnWidth(
                    min: panelLayout.minWidth(for: .right),
                    ideal: panelLayout.idealWidth(for: .right),
                    max: panelLayout.maxWidth(for: .right)
                )
                .toolbarBackground(.hidden, for: .windowToolbar)
                .toolbarColorScheme(colorScheme, for: .windowToolbar)
        }
        .preferredColorScheme(colorScheme)
        .environment(\.colorScheme, colorScheme)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbarColorScheme(colorScheme, for: .windowToolbar)
        .background(Color(theme.background).ignoresSafeArea())
        .background(WindowAppearanceConfigurator(theme: theme))
    }
}
