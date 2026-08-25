import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentInputAttachmentThumbnailView: View {
    public let images: [AgentImageAttachment]
    public let theme: Theme
    public var onSelect: (Int) -> Void
    public var onDelete: (Int) -> Void

    public init(
        images: [AgentImageAttachment],
        theme: Theme,
        onSelect: @escaping (Int) -> Void,
        onDelete: @escaping (Int) -> Void
    ) {
        self.images = images
        self.theme = theme
        self.onSelect = onSelect
        self.onDelete = onDelete
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, item in
                    SingleThumbnailCard(
                        item: item,
                        theme: theme,
                        onClick: { onSelect(index) },
                        onDelete: { onDelete(index) }
                    )
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .frame(height: 64)
    }
}

private struct SingleThumbnailCard: View {
    let item: AgentImageAttachment
    let theme: Theme
    let onClick: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onClick) {
                if let nsImage = NSImage(data: item.data) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    isHovered ? Color.accentColor.opacity(0.8) : Color(theme.excerptHeaderBorder).opacity(0.8),
                                    lineWidth: isHovered ? 1.5 : 1
                                )
                        )
                        .shadow(
                            color: isHovered ? Color.black.opacity(0.25) : Color.black.opacity(0.08),
                            radius: isHovered ? 6 : 2,
                            y: isHovered ? 2 : 1
                        )
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(theme.gutterBackground))
                        .frame(width: 52, height: 52)
                        .overlay(
                            Image(systemName: "photo")
                                .foregroundColor(Color(theme.gutterForeground))
                        )
                }
            }
            .buttonStyle(.plain)
            .help("Click to preview (\(item.filename ?? "image"))")

            // Delete badge button
            Button(action: onDelete) {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                        .frame(width: 18, height: 18)

                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.primary.opacity(0.85))
                }
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .opacity(isHovered ? 1.0 : 0.75)
            .help("Remove image")
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
