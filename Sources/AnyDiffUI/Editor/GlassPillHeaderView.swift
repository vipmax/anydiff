import SwiftUI
import AppKit
import AnyDiffCore

// MARK: - Chevron Vector Shape (Pixel-matched to in-stream header)

struct ChevronShape: Shape {
    let isCollapsed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let cx = rect.midX
        let cy = rect.midY
        if isCollapsed {
            path.move(to: CGPoint(x: cx - 2.5, y: cy - 4.5))
            path.addLine(to: CGPoint(x: cx + 2.5, y: cy))
            path.addLine(to: CGPoint(x: cx - 2.5, y: cy + 4.5))
        } else {
            path.move(to: CGPoint(x: cx - 4.5, y: cy - 2.5))
            path.addLine(to: CGPoint(x: cx, y: cy + 2.5))
            path.addLine(to: CGPoint(x: cx + 4.5, y: cy - 2.5))
        }
        return path
    }
}

// MARK: - View Model

public final class GlassPillViewModel: ObservableObject {
    @Published public var info: ExcerptHeaderInfo?
    @Published public var theme: Theme = .vesper
    @Published public var isCloseHovered: Bool = false
    @Published public var isPreviewHovered: Bool = false

    public init() {}
}

// MARK: - Native Liquid Glass Pill View (SwiftUI)

public struct NativeLiquidGlassPillView: View {
    @ObservedObject public var model: GlassPillViewModel

    public var onToggleCollapse: ((String) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onPreviewMarkdown: ((String) -> Void)?
    public var onOpenExternalIDE: ((String, Int?) -> Void)?

    public init(
        model: GlassPillViewModel,
        onToggleCollapse: ((String) -> Void)? = nil,
        onClose: ((String) -> Void)? = nil,
        onPreviewMarkdown: ((String) -> Void)? = nil,
        onOpenExternalIDE: ((String, Int?) -> Void)? = nil
    ) {
        self.model = model
        self.onToggleCollapse = onToggleCollapse
        self.onClose = onClose
        self.onPreviewMarkdown = onPreviewMarkdown
        self.onOpenExternalIDE = onOpenExternalIDE
    }

    public var body: some View {
        if let info = model.info {
            pillWrapper {
                pillContent(info: info)
            }
        }
    }

    @ViewBuilder
    private func pillWrapper<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content()
                    .glassEffect(.regular.interactive())
            }
        } else {
            content()
                .background(.thinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.20), radius: 6, x: 0, y: 2)
        }
    }

    private func pillContent(info: ExcerptHeaderInfo) -> some View {
        let isMd = info.filePath.hasSuffix(".md") || info.filePath.hasSuffix(".markdown") || info.filePath.hasSuffix(".mdx")
        let fileName = (info.filePath as NSString).lastPathComponent
        let dir = (info.filePath as NSString).deletingLastPathComponent

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 1. Chevron Toggle (Precisely centered at x = 14 to match in-stream header)
                Button(action: {
                    if NSEvent.modifierFlags.contains(.option) {
                        onOpenExternalIDE?(info.filePath, nil)
                    } else {
                        onToggleCollapse?(info.filePath)
                    }
                }) {
                    ChevronShape(isCollapsed: info.isCollapsed)
                        .stroke(
                            Color(model.theme.gutterForeground).opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: 14, y: geo.size.height / 2.0)

                // 2. File Icon / Close Button on hover (Frame x: 24..42, centered at x = 33)
                Button(action: {
                    if model.isCloseHovered {
                        onClose?(info.filePath)
                    } else if NSEvent.modifierFlags.contains(.option) {
                        onOpenExternalIDE?(info.filePath, nil)
                    } else {
                        onToggleCollapse?(info.filePath)
                    }
                }) {
                    ZStack {
                        if model.isCloseHovered {
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(Color(model.theme.foreground))
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color(model.theme.gutterForeground).opacity(0.22)))
                        } else {
                            Image(nsImage: FileIconProvider.shared.image(for: info.filePath, pointSize: 12, weight: .medium))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .position(x: 33, y: geo.size.height / 2.0)
                .onHover { hovering in
                    model.isCloseHovered = hovering
                }

                // 3. File Name and Directory (Starts precisely at x = 50)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(titleColor(for: info.fileStatus))
                        .lineLimit(1)

                    if !dir.isEmpty && dir != "." {
                        Text("  " + dir)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundColor(Color(model.theme.gutterForeground))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 16)
                }
                .padding(.leading, 50)
                .padding(.trailing, isMd ? 120 : 90)
                .frame(maxHeight: .infinity, alignment: .leading)

                // 4. Right side: Diff Badges (+N -M) and Preview Button
                HStack(spacing: 10) {
                    if info.deletions > 0 || info.additions > 0 {
                        HStack(spacing: 10) {
                            if info.additions > 0 {
                                Text("+\(info.additions)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(model.theme.diffAddedGutter))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            if info.deletions > 0 {
                                Text("-\(info.deletions)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(Color(model.theme.diffDeletedGutter))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                    }

                    if isMd {
                        Button(action: { onPreviewMarkdown?(info.filePath) }) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(model.isPreviewHovered ? Color(model.theme.foreground) : Color(model.theme.gutterForeground))
                                .frame(width: 18, height: 18)
                                .background(
                                    model.isPreviewHovered ? Circle().fill(Color(model.theme.gutterForeground).opacity(0.22)) : nil
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Preview Markdown")
                        .onHover { hovering in
                            model.isPreviewHovered = hovering
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, isMd ? 8 : 14)
            }
        }
        .frame(height: 26)
    }

    private func titleColor(for status: FileDiffStatus) -> Color {
        switch status {
        case .added:
            return Color(model.theme.diffAddedGutter)
        case .deleted:
            return Color(model.theme.diffDeletedGutter)
        case .renamed:
            return Color(model.theme.diffModifiedGutter)
        default:
            return Color(model.theme.foreground)
        }
    }
}

// MARK: - AppKit Wrapper View

/// A floating liquid glass pill view providing real native Apple Liquid Glass
/// (`GlassEffectContainer` + `.glassEffect(.regular.interactive())` on macOS 26.0+)
/// for pinned (sticky) multi-buffer editor file headers.
public final class GlassPillHeaderView: NSView {

    // MARK: - Properties

    private let model = GlassPillViewModel()
    private var hostingView: NSHostingView<NativeLiquidGlassPillView>?

    // MARK: - Callbacks

    public var onToggleCollapse: ((String) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onPreviewMarkdown: ((String) -> Void)?
    public var onOpenExternalIDE: ((String, Int?) -> Void)?

    public var currentInfo: ExcerptHeaderInfo? {
        model.info
    }

    public var isCollapsed: Bool {
        model.info?.isCollapsed ?? false
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false

        let swiftUIView = NativeLiquidGlassPillView(
            model: model,
            onToggleCollapse: { [weak self] path in self?.onToggleCollapse?(path) },
            onClose: { [weak self] path in self?.onClose?(path) },
            onPreviewMarkdown: { [weak self] path in self?.onPreviewMarkdown?(path) },
            onOpenExternalIDE: { [weak self] path, line in self?.onOpenExternalIDE?(path, line) }
        )
        let hv = NSHostingView(rootView: swiftUIView)
        hv.frame = bounds
        hv.autoresizingMask = [.width, .height]
        addSubview(hv)
        self.hostingView = hv
    }

    // MARK: - Update

    public func update(info: ExcerptHeaderInfo, theme: Theme) {
        if model.info != info {
            model.info = info
        }
        if model.theme.name != theme.name {
            model.theme = theme
        }
    }

    public override func layout() {
        super.layout()
        hostingView?.frame = bounds
    }

    public override var isFlipped: Bool { true }
}
