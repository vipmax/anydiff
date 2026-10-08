import SwiftUI
import AppKit
import AnyDiffCore

@MainActor
public final class CompletionStateModel: ObservableObject {
    @Published public var items: [LSPCompletionItem] = []
    @Published public var selectedIndex: Int = 0
    @Published public var queryPrefix: String = ""
    public var onSelect: ((LSPCompletionItem) -> Void)?

    public init(
        items: [LSPCompletionItem] = [],
        selectedIndex: Int = 0,
        queryPrefix: String = "",
        onSelect: ((LSPCompletionItem) -> Void)? = nil
    ) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.queryPrefix = queryPrefix
        self.onSelect = onSelect
    }
}

/// Native macOS blur matching NSPopover
public struct VisualEffectBackground: NSViewRepresentable {
    public let material: NSVisualEffectView.Material
    public let blendingMode: NSVisualEffectView.BlendingMode
    public let state: NSVisualEffectView.State

    public init(
        material: NSVisualEffectView.Material = .popover,
        blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.wantsLayer = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

public struct CompletionMenuView: View {
    @ObservedObject public var model: CompletionStateModel
    public let theme: Theme

    public init(model: CompletionStateModel, theme: Theme) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        CompletionItemRow(
                            item: item,
                            isSelected: index == model.selectedIndex,
                            queryPrefix: model.queryPrefix,
                            theme: theme
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedIndex = index
                            model.onSelect?(item)
                        }
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 5)
            }
            .onChange(of: model.selectedIndex) { newIndex in
                withAnimation(.easeInOut(duration: 0.08)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
        .frame(width: 320, height: calculatedHeight)
    }

    private var calculatedHeight: CGFloat {
        let count = max(1, min(8, model.items.count))
        return CGFloat(count) * 26 + 10
    }
}

private struct CompletionItemRow: View {
    let item: LSPCompletionItem
    let isSelected: Bool
    let queryPrefix: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            // Kind Badge (Zed-styled letter with colored pill)
            badgeView

            // Main Label with matched prefix highlight
            highlightedLabel
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(isSelected ? .white : Color(theme.foreground))
                .lineLimit(1)

            Spacer(minLength: 6)

            // Detail / Type signature (e.g. String, (Int) -> Void)
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(isSelected ? Color.white.opacity(0.85) : Color(theme.gutterForeground))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? selectionColor : Color.clear)
        )
    }

    private var selectionColor: Color {
        Color.accentColor.opacity(0.4)
    }

    private var badgeView: some View {
        let badge = item.kind?.badge ?? "v"
        let color = badgeColor(for: item.kind)
        return Text(badge)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 17, height: 17)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.20))
            )
    }

    @ViewBuilder
    private var highlightedLabel: some View {
        let label = item.label
        if !queryPrefix.isEmpty, let range = label.range(of: queryPrefix, options: .caseInsensitive) {
            let before = String(label[..<range.lowerBound])
            let match = String(label[range])
            let after = String(label[range.upperBound...])

            HStack(spacing: 0) {
                if !before.isEmpty {
                    Text(before)
                }
                Text(match)
                    .bold()
                    .underline(true, color: Color.accentColor)
                if !after.isEmpty {
                    Text(after)
                }
            }
        } else {
            Text(label)
        }
    }

    private func badgeColor(for kind: LSPCompletionItemKind?) -> Color {
        switch kind {
        case .method, .function, .constructor:
            return Color(red: 0.65, green: 0.55, blue: 0.98) // Violet / Purple
        case .variable, .field, .property:
            return Color(red: 0.38, green: 0.65, blue: 0.98) // Sky Blue
        case .struct, .class, .interface, .enum, .typeParameter:
            return Color(red: 0.98, green: 0.75, blue: 0.18) // Amber
        case .keyword:
            return Color(red: 0.96, green: 0.45, blue: 0.71) // Pink / Magenta
        case .module:
            return Color(red: 0.20, green: 0.83, blue: 0.60) // Emerald Green
        case .constant:
            return Color(red: 0.22, green: 0.80, blue: 0.80) // Cyan
        case .snippet:
            return Color(red: 0.60, green: 0.64, blue: 0.72) // Gray
        default:
            return Color(red: 0.50, green: 0.55, blue: 0.65)
        }
    }
}
