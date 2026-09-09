import SwiftUI
import AnyDiffCore

public struct StandardPanelHeaderTitleView: View {
    public var title: String
    public var iconName: String?
    public var theme: Theme

    public init(title: String, iconName: String? = nil, theme: Theme) {
        self.title = title
        self.iconName = iconName
        self.theme = theme
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let icon = iconName {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color(theme.gutterForeground))
            }

            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(theme.gutterForeground))
                .lineLimit(1)
        }
        .padding(.leading, iconName == nil ? 4 : 0)
    }
}

public struct PanelHeaderBackButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.secondary.opacity(configuration.isPressed ? 0.24 : 0.14) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

public struct PanelHeaderView<TitleView: View, Actions: View>: View {
    public var theme: Theme
    public var onBack: (() -> Void)?
    public var titleView: TitleView
    public var actions: Actions

    @State private var isHeaderHovered = false

    public init(
        theme: Theme,
        onBack: (() -> Void)? = nil,
        @ViewBuilder titleView: () -> TitleView,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.theme = theme
        self.onBack = onBack
        self.titleView = titleView()
        self.actions = actions()
    }

    public var body: some View {
        HStack(spacing: 0) {
            if let onBack = onBack {
                Button(action: onBack) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(theme.gutterForeground))
                }
                .buttonStyle(PanelHeaderBackButtonStyle())
                .help("Close panel (choose different view)")
                .padding(.leading, 5)
                .padding(.trailing, 1)
                .opacity(isHeaderHovered ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.14), value: isHeaderHovered)
            } else {
                Spacer()
                    .frame(width: 10)
            }

            titleView
                .lineLimit(1)

            Spacer(minLength: 4)

            actions
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .padding(.trailing, 16)
        }
        .frame(height: 28)
        .background(Color(theme.background))
        .overlay(
            Rectangle()
                .fill(Color(theme.gutterForeground).opacity(0.15))
                .frame(height: 1),
            alignment: .bottom
        )
        .onHover { isHeaderHovered = $0 }
    }
}

extension PanelHeaderView where TitleView == StandardPanelHeaderTitleView {
    public init(
        title: String,
        iconName: String? = nil,
        theme: Theme,
        onBack: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.init(
            theme: theme,
            onBack: onBack,
            titleView: {
                StandardPanelHeaderTitleView(title: title, iconName: iconName, theme: theme)
            },
            actions: actions
        )
    }
}
