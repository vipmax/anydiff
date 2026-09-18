import SwiftUI
import AnyDiffCore

public struct EmptyPanelView: View {
    public var slot: PanelSlot
    public var theme: Theme
    public var currentOccupant: (PanelContent) -> PanelSlot?
    public var onSelect: (PanelContent) -> Void

    @State private var hoveredContent: PanelContent? = nil

    public init(
        slot: PanelSlot,
        theme: Theme,
        currentOccupant: @escaping (PanelContent) -> PanelSlot?,
        onSelect: @escaping (PanelContent) -> Void
    ) {
        self.slot = slot
        self.theme = theme
        self.currentOccupant = currentOccupant
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(theme.background)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    Spacer(minLength: 20)

                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 26, weight: .light))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

                        Text("Select Panel View")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(theme.foreground))

                        Text("Choose what to display in the \(slot.title.lowercased()).")
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(theme.gutterForeground))
                            .multilineTextAlignment(.center)
                    }

                    if proxy.size.width > 440 {
                        HStack(spacing: 12) {
                            ForEach(PanelContent.allCases) { content in
                                cardView(for: content, isNarrow: false)
                            }
                        }
                        .padding(.horizontal, 20)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(PanelContent.allCases) { content in
                                cardView(for: content, isNarrow: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: 320)
                    }

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func cardView(for content: PanelContent, isNarrow: Bool) -> some View {
        let isHovered = (hoveredContent == content)
        let otherSlot = currentOccupant(content)
        let isHere = (otherSlot == slot)

        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                onSelect(content)
            }
        }) {
            Group {
                if isNarrow {
                    // Row layout for narrow columns
                    HStack(spacing: 12) {
                        iconBadge(for: content, size: 36, isHovered: isHovered)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(content.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(Color(theme.foreground))

                                if let other = otherSlot, !isHere {
                                    slotBadge(for: other)
                                }
                            }

                            Text(content.description)
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(theme.gutterForeground))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(theme.gutterForeground).opacity(isHovered ? 0.9 : 0.4))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                } else {
                    // Square card layout for wide areas
                    VStack(spacing: 10) {
                        if let other = otherSlot, !isHere {
                            slotBadge(for: other)
                        } else {
                            // Placeholder to align vertical spacing
                            Text("")
                                .font(.system(size: 9))
                                .frame(height: 14)
                        }

                        iconBadge(for: content, size: 44, isHovered: isHovered)

                        VStack(spacing: 4) {
                            Text(content.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Color(theme.foreground))

                            Text(content.description)
                                .font(.system(size: 10.5))
                                .foregroundColor(Color(theme.gutterForeground))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(width: 140, height: 160)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered
                          ? Color(theme.gutterBackground).opacity(0.85)
                          : Color(theme.gutterBackground).opacity(0.4))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered
                            ? accentColor(for: content).opacity(0.6)
                            : Color(theme.gutterForeground).opacity(0.18),
                        lineWidth: isHovered ? 1.5 : 1
                    )
            )
            .shadow(
                color: isHovered ? accentColor(for: content).opacity(0.12) : Color.clear,
                radius: 8,
                y: 2
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredContent = hovering ? content : nil
        }
    }

    @ViewBuilder
    private func iconBadge(for content: PanelContent, size: CGFloat, isHovered: Bool) -> some View {
        let color = accentColor(for: content)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(isHovered ? 0.2 : 0.12))
                .frame(width: size, height: size)

            Image(systemName: content.iconName)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(color)
        }
    }

    @ViewBuilder
    private func slotBadge(for slot: PanelSlot) -> some View {
        Text("In \(slot.title.replacingOccurrences(of: " Panel", with: ""))")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.accentColor.opacity(0.12))
            .cornerRadius(4)
    }

    private func accentColor(for content: PanelContent) -> Color {
        switch content {
        case .changes:
            return Color.orange
        case .files:
            return Color.teal
        case .history:
            return Color.indigo
        case .editor:
            return Color.blue
        case .agent:
            return Color.purple
        }
    }
}
