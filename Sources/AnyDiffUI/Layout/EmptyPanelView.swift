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
            let availableWidth = proxy.size.width
            ZStack {
                Color(theme.background)
                    .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: vStackSpacing(for: availableWidth)) {
                        Spacer(minLength: topSpacing(for: availableWidth))

                        headerView(for: availableWidth)

                        cardsContent(for: availableWidth)

                        Spacer(minLength: bottomSpacing(for: availableWidth))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerView(for availableWidth: CGFloat) -> some View {
        if availableWidth < 110 {
            // Rail mode: minimal icon only
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16, weight: .light))
                .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                .help("Select view for \(slot.title.lowercased())")
                .padding(.top, 4)
        } else if availableWidth < 220 {
            // Compact mode: small icon + single-line title, no multi-line subtitle
            VStack(spacing: 3) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

                Text("Select View")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))
                    .lineLimit(1)
            }
            .padding(.top, 6)
        } else {
            // Full header
            VStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

                Text("Select Panel View")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))
                    .lineLimit(1)

                Text("Choose what to display in the \(slot.title.lowercased()).")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(theme.gutterForeground))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .padding(.top, 14)
        }
    }

    // MARK: - Content Breakpoints

    @ViewBuilder
    private func cardsContent(for availableWidth: CGFloat) -> some View {
        let allCases = PanelContent.allCases
        let cardWidth: CGFloat = 140
        let spacing: CGFloat = 12
        let singleRowNeededWidth = CGFloat(allCases.count) * cardWidth + CGFloat(max(0, allCases.count - 1)) * spacing + 40
        let maxCardsInTwoRowTop = (allCases.count + 1) / 2
        let twoRowsMinNeededWidth = CGFloat(maxCardsInTwoRowTop) * cardWidth + CGFloat(max(0, maxCardsInTwoRowTop - 1)) * spacing + 24

        if availableWidth >= singleRowNeededWidth {
            // Tier 1: Single wide horizontal row (6 cards)
            HStack(spacing: spacing) {
                ForEach(allCases) { content in
                    cardButton(for: content) {
                        wideCardView(for: content)
                    }
                }
            }
            .padding(.horizontal, 20)
        } else if availableWidth >= twoRowsMinNeededWidth {
            // Tier 2: 2 rows of 3 cards each (cards are 140x160)
            let midIndex = (allCases.count + 1) / 2
            let firstRow = Array(allCases.prefix(midIndex))
            let secondRow = Array(allCases.suffix(from: midIndex))

            VStack(spacing: spacing) {
                HStack(spacing: spacing) {
                    ForEach(firstRow) { content in
                        cardButton(for: content) {
                            wideCardView(for: content)
                        }
                    }
                }
                HStack(spacing: spacing) {
                    ForEach(secondRow) { content in
                        cardButton(for: content) {
                            wideCardView(for: content)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        } else if availableWidth >= 220 {
            // Tier 3: Standard sidebar list row
            VStack(spacing: 8) {
                ForEach(allCases) { content in
                    cardButton(for: content) {
                        standardRowView(for: content)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: 380)
        } else if availableWidth >= 110 {
            // Tier 4: Compact row (Icon + single-line title, zero vertical text stacking)
            VStack(spacing: 5) {
                ForEach(allCases) { content in
                    cardButton(for: content) {
                        compactRowView(for: content)
                    }
                }
            }
            .padding(.horizontal, 8)
        } else {
            // Tier 5: Ultra-compact Rail (centered 32x32 icons with tooltips)
            VStack(spacing: 6) {
                ForEach(allCases) { content in
                    cardButton(for: content) {
                        railIconView(for: content)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Button Wrapper

    @ViewBuilder
    private func cardButton<V: View>(for content: PanelContent, @ViewBuilder contentBuilder: () -> V) -> some View {
        let isHovered = (hoveredContent == content)
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                onSelect(content)
            }
        }) {
            contentBuilder()
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered
                              ? Color(theme.gutterBackground).opacity(0.85)
                              : Color(theme.gutterBackground).opacity(0.35))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isHovered
                                ? accentColor(for: content).opacity(0.6)
                                : Color(theme.gutterForeground).opacity(0.18),
                            lineWidth: isHovered ? 1.5 : 1
                        )
                )
                .shadow(
                    color: isHovered ? accentColor(for: content).opacity(0.12) : Color.clear,
                    radius: 6,
                    y: 2
                )
                .scaleEffect(isHovered ? 1.015 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredContent = hovering ? content : nil
        }
    }

    // MARK: - Layout Views

    @ViewBuilder
    private func wideCardView(for content: PanelContent) -> some View {
        let isHovered = (hoveredContent == content)
        let otherSlot = currentOccupant(content)
        let isHere = (otherSlot == slot)

        VStack(spacing: 10) {
            if let other = otherSlot, !isHere {
                slotBadge(for: other)
            } else {
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

    @ViewBuilder
    private func standardRowView(for content: PanelContent) -> some View {
        let isHovered = (hoveredContent == content)
        let otherSlot = currentOccupant(content)
        let isHere = (otherSlot == slot)

        HStack(spacing: 10) {
            iconBadge(for: content, size: 30, isHovered: isHovered)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(content.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                        .lineLimit(1)

                    if let other = otherSlot, !isHere {
                        slotBadge(for: other)
                    }
                }

                Text(content.description)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(theme.gutterForeground))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(theme.gutterForeground).opacity(isHovered ? 0.9 : 0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func compactRowView(for content: PanelContent) -> some View {
        let isHovered = (hoveredContent == content)
        let otherSlot = currentOccupant(content)
        let isHere = (otherSlot == slot)

        HStack(spacing: 8) {
            iconBadge(for: content, size: 24, isHovered: isHovered)

            Text(content.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(theme.foreground))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            if let other = otherSlot, !isHere {
                slotBadge(for: other, compact: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .help("\(content.title) — \(content.description)")
    }

    @ViewBuilder
    private func railIconView(for content: PanelContent) -> some View {
        let isHovered = (hoveredContent == content)
        let otherSlot = currentOccupant(content)
        let isHere = (otherSlot == slot)

        ZStack(alignment: .topTrailing) {
            iconBadge(for: content, size: 28, isHovered: isHovered)

            if otherSlot != nil, !isHere {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: 34, height: 34)
        .help("\(content.title) — \(content.description)")
    }

    // MARK: - Components

    @ViewBuilder
    private func iconBadge(for content: PanelContent, size: CGFloat, isHovered: Bool) -> some View {
        let color = accentColor(for: content)
        ZStack {
            RoundedRectangle(cornerRadius: size > 28 ? 8 : 6, style: .continuous)
                .fill(color.opacity(isHovered ? 0.22 : 0.12))
                .frame(width: size, height: size)

            Image(systemName: content.iconName)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundColor(color)
        }
    }

    @ViewBuilder
    private func slotBadge(for slot: PanelSlot, compact: Bool = false) -> some View {
        if compact {
            Text(String(slot.title.replacingOccurrences(of: " Panel", with: "").prefix(1)))
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.accentColor)
                .frame(width: 14, height: 14)
                .background(Color.accentColor.opacity(0.16))
                .clipShape(Circle())
        } else {
            Text("In \(slot.title.replacingOccurrences(of: " Panel", with: ""))")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(4)
        }
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
        case .terminal:
            return Color.green
        }
    }

    // MARK: - Responsive Spacing

    private func vStackSpacing(for width: CGFloat) -> CGFloat {
        if width < 110 {
            return 8
        } else if width < 220 {
            return 10
        } else {
            return 18
        }
    }

    private func topSpacing(for width: CGFloat) -> CGFloat {
        if width < 110 {
            return 8
        } else if width < 220 {
            return 10
        } else {
            return 18
        }
    }

    private func bottomSpacing(for width: CGFloat) -> CGFloat {
        if width < 220 {
            return 10
        } else {
            return 20
        }
    }
}
