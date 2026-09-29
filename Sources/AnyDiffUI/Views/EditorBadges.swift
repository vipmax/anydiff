import SwiftUI
import AnyDiffCore

public struct MarkdownPreviewBadge: View {
    public let path: String
    public let theme: Theme
    public let onClose: () -> Void

    @State private var isBadgeHovered = false
    @State private var isCloseHovered = false

    public init(path: String, theme: Theme, onClose: @escaping () -> Void) {
        self.path = path
        self.theme = theme
        self.onClose = onClose
    }

    public var body: some View {
        let fileName = (path as NSString).lastPathComponent
        Button(action: onClose) {
            HStack(spacing: 5) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.accentColor)

                Text(fileName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isBadgeHovered ? Color(theme.foreground) : Color(theme.foreground).opacity(0.85))
                    .lineLimit(1)

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isCloseHovered ? Color.accentColor : Color.accentColor.opacity(0.85))
                    .frame(width: 15, height: 15)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? Color.accentColor.opacity(0.25) : Color.accentColor.opacity(0.14))
                    )
                    .onHover { isCloseHovered = $0 }
            }
            .padding(.leading, 7.5)
            .padding(.trailing, 4.5)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isBadgeHovered ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.11))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isBadgeHovered ? Color.accentColor.opacity(0.32) : Color.accentColor.opacity(0.20), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help("Close Preview (Esc)")
        .accessibilityLabel("Close Preview")
        .onHover { isBadgeHovered = $0 }
        .fixedSize()
    }
}

public struct GlobalSearchBadge: View {
    public let theme: Theme
    public let onClose: () -> Void

    @State private var isBadgeHovered = false
    @State private var isCloseHovered = false

    public init(theme: Theme, onClose: @escaping () -> Void) {
        self.theme = theme
        self.onClose = onClose
    }

    public var body: some View {
        Button(action: onClose) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.accentColor)

                Text("Global Search")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isBadgeHovered ? Color(theme.foreground) : Color(theme.foreground).opacity(0.85))

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isCloseHovered ? Color.accentColor : Color.accentColor.opacity(0.85))
                    .frame(width: 15, height: 15)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? Color.accentColor.opacity(0.25) : Color.accentColor.opacity(0.14))
                    )
                    .onHover { isCloseHovered = $0 }
            }
            .padding(.leading, 7.5)
            .padding(.trailing, 4.5)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isBadgeHovered ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.11))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isBadgeHovered ? Color.accentColor.opacity(0.32) : Color.accentColor.opacity(0.20), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help("Exit Search (Esc)")
        .accessibilityLabel("Exit Search")
        .onHover { isBadgeHovered = $0 }
        .fixedSize()
    }
}

public struct ReadOnlyDiffBadge: View {
    public let isCommit: Bool
    public let theme: Theme
    public let onClose: () -> Void

    @State private var isBadgeHovered = false
    @State private var isCloseHovered = false

    public init(isCommit: Bool, theme: Theme, onClose: @escaping () -> Void) {
        self.isCommit = isCommit
        self.theme = theme
        self.onClose = onClose
    }

    public var body: some View {
        Button(action: onClose) {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(isBadgeHovered ? Color(theme.foreground) : Color(theme.gutterForeground))

                Text("Read-Only")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isBadgeHovered ? Color(theme.foreground) : Color(theme.foreground).opacity(0.85))

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isCloseHovered ? Color(theme.foreground) : Color(theme.gutterForeground))
                    .frame(width: 15, height: 15)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? Color(theme.foreground).opacity(0.16) : Color(theme.gutterForeground).opacity(0.12))
                    )
                    .onHover { isCloseHovered = $0 }
            }
            .padding(.leading, 7.5)
            .padding(.trailing, 4.5)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isBadgeHovered ? Color(theme.gutterForeground).opacity(0.20) : Color(theme.gutterForeground).opacity(0.11))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isBadgeHovered ? Color(theme.gutterForeground).opacity(0.32) : Color(theme.gutterForeground).opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help(isCommit ? "Return to Working Changes (Esc)" : "Exit Review (Esc)")
        .accessibilityLabel(isCommit ? "Return to Working Changes" : "Exit Review")
        .onHover { isBadgeHovered = $0 }
        .fixedSize()
    }
}

public struct ReadOnlyBadge: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9.5))
            Text("Read-Only")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.secondary)
        .fixedSize()
        .help("Read-only mode.")
    }
}
