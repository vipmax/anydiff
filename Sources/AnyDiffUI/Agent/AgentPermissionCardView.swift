import SwiftUI
import AnyDiffCore

/// Inline permission prompt shown above the input so it never covers chat content.
public struct AgentPermissionCardView: View {
    public let permission: AgentPermissionRequest
    public let theme: Theme
    public var onRespond: (String) -> Void

    public init(
        permission: AgentPermissionRequest,
        theme: Theme,
        onRespond: @escaping (String) -> Void
    ) {
        self.permission = permission
        self.theme = theme
        self.onRespond = onRespond
    }

    private let warning = Color.orange

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(warning)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(warning)
                    Text("Permission required")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(warning)
                }

                Text(permission.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Color(theme.foreground))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let command = permission.command, !command.isEmpty, command != permission.title {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(theme.foreground).opacity(0.85))
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(theme.background).opacity(0.7))
                        )
                }

                optionsView
            }
            .padding(.leading, 10)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(theme.background))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(warning.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(warning.opacity(0.35), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var optionsView: some View {
        let options = permission.options
        let compact = options.count <= 3 && options.allSatisfy { $0.name.count <= 22 }
        if compact {
            HStack(spacing: 6) {
                ForEach(options) { optionButton($0) }
            }
        } else {
            VStack(spacing: 5) {
                ForEach(options) { optionButton($0, fill: true) }
            }
        }
    }

    private func optionButton(_ option: ACPPermissionOption, fill: Bool = false) -> some View {
        let style = Self.style(for: option)
        let tint: Color = style == .allow ? .green : (style == .reject ? .red : Color(theme.foreground))
        return Button {
            onRespond(option.optionId)
        } label: {
            Text(option.name)
                .font(.system(size: 11.5, weight: .medium))
                .multilineTextAlignment(.leading)
                .foregroundColor(style == .allow ? Color.white : tint.opacity(style == .other ? 0.9 : 1))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: fill ? .infinity : nil, alignment: fill ? .leading : .center)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(style == .allow ? Color.green.opacity(0.85) : tint.opacity(style == .other ? 0.08 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(tint.opacity(style == .allow ? 0 : 0.25), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private enum OptionStyle { case allow, reject, other }

    private static func style(for option: ACPPermissionOption) -> OptionStyle {
        let kind = option.kind?.lowercased() ?? ""
        if kind.contains("reject") { return .reject }
        if kind.contains("allow") { return .allow }
        return .other
    }
}
