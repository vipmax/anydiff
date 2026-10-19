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
    public static let defaultWidth: CGFloat = 480
    public static let rowHeight: CGFloat = 28
    public static let maxVisibleRows: Int = 10

    public static func calculateHeight(itemCount: Int) -> CGFloat {
        let count = max(1, min(maxVisibleRows, itemCount))
        return CGFloat(count) * rowHeight + 10
    }

    @ObservedObject public var model: CompletionStateModel
    public let theme: Theme

    @State private var firstVisibleIndex: Int = 0

    private var maxVisibleCount: Int {
        Self.maxVisibleRows
    }

    private var lastVisibleIndex: Int {
        firstVisibleIndex + maxVisibleCount - 1
    }

    public init(model: CompletionStateModel, theme: Theme) {
        self.model = model
        self.theme = theme
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: model.items.count > Self.maxVisibleRows) {
                LazyVStack(spacing: 2) {
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
            .onAppear {
                firstVisibleIndex = 0
                proxy.scrollTo(0, anchor: .top)
            }
            .onChange(of: model.queryPrefix) { _ in
                firstVisibleIndex = 0
                proxy.scrollTo(0, anchor: .top)
            }
            .onChange(of: model.items.count) { _ in
                firstVisibleIndex = 0
                proxy.scrollTo(0, anchor: .top)
            }
            .onChange(of: model.selectedIndex) { newIndex in
                guard !model.items.isEmpty else { return }
                let count = model.items.count
                if count <= maxVisibleCount {
                    return
                }

                if newIndex == 0 {
                    firstVisibleIndex = 0
                    withAnimation(.easeOut(duration: 0.05)) {
                        proxy.scrollTo(0, anchor: .top)
                    }
                } else if newIndex == count - 1 && firstVisibleIndex == 0 {
                    firstVisibleIndex = max(0, count - maxVisibleCount)
                    withAnimation(.easeOut(duration: 0.05)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                } else {
                    let desiredBottom = min(count - 1, newIndex + 1)
                    let desiredTop = max(0, newIndex - 1)

                    if desiredBottom > lastVisibleIndex {
                        firstVisibleIndex = desiredBottom - maxVisibleCount + 1
                        withAnimation(.easeOut(duration: 0.05)) {
                            proxy.scrollTo(desiredBottom, anchor: .bottom)
                        }
                    } else if desiredTop < firstVisibleIndex {
                        firstVisibleIndex = desiredTop
                        withAnimation(.easeOut(duration: 0.05)) {
                            proxy.scrollTo(desiredTop, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(width: Self.defaultWidth, height: calculatedHeight)
    }

    private var calculatedHeight: CGFloat {
        Self.calculateHeight(itemCount: model.items.count)
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
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundColor(isSelected ? .white : Color(theme.foreground))
                .lineLimit(1)

            Spacer(minLength: 8)

            // Detail / Type signature (e.g. String, (Int) -> Void, Bool)
            if let detail = item.detail, !detail.isEmpty {
                let cleanDetail = detail.replacingOccurrences(of: "\n", with: " ")
                Text(cleanDetail)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundColor(isSelected ? Color.white.opacity(0.9) : Color(theme.gutterForeground))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? selectionColor : Color.clear)
        )
    }

    private var selectionColor: Color {
        Color.accentColor
    }

    private var badgeView: some View {
        let badge = item.kind?.badge ?? "v"
        let color = badgeColor(for: item.kind)
        return Text(badge)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .minimumScaleFactor(0.7)
            .foregroundColor(isSelected ? .white : color)
            .frame(width: 20, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.25) : color.opacity(0.20))
            )
    }

    @ViewBuilder
    private var highlightedLabel: some View {
        let label = item.label
        if !queryPrefix.isEmpty, let range = label.range(of: queryPrefix, options: .caseInsensitive) {
            let before = String(label[..<range.lowerBound])
            let match = String(label[range])
            let after = String(label[range.upperBound...])

            Text(before)
                + Text(match).bold().underline(true, color: isSelected ? .white : Color.accentColor)
                + Text(after)
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
            return Color(red: 0.60, green: 0.64, blue: 0.72) // Slate / Gray
        default:
            return Color(red: 0.50, green: 0.55, blue: 0.65)
        }
    }
}

