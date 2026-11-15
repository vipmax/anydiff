import AppKit
import AnyDiffCore

public enum MermaidRenderResult: Sendable {
    case diagram(MermaidLayoutDiagram, palette: MermaidThemePalette)
    case failure(String)
}

public final class MermaidCachedEntry: NSObject, @unchecked Sendable {
    public let result: MermaidRenderResult

    init(result: MermaidRenderResult) {
        self.result = result
    }
}

public final class MermaidRenderCache: @unchecked Sendable {
    public static let shared = MermaidRenderCache()

    private let cache = NSCache<NSString, MermaidCachedEntry>()
    private let renderQueue = DispatchQueue(
        label: "app.anydiff.mermaid.render",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let measurer = MermaidCoreTextMeasurer()

    private init() {
        cache.countLimit = 128
    }

    public func cacheKey(code: String, themeID: String, maxWidth: CGFloat) -> NSString {
        let widthBucket = Int((max(320, maxWidth) / 40).rounded() * 40)
        return "\(themeID)|\(widthBucket)|\(code)" as NSString
    }

    public func cachedResult(code: String, theme: Theme, maxWidth: CGFloat) -> MermaidRenderResult? {
        let key = cacheKey(code: code, themeID: theme.id, maxWidth: maxWidth)
        return cache.object(forKey: key)?.result
    }

    public func renderAsync(
        code: String,
        theme: Theme,
        maxWidth: CGFloat,
        completion: @escaping @MainActor (MermaidRenderResult) -> Void
    ) {
        let key = cacheKey(code: code, themeID: theme.id, maxWidth: maxWidth)
        if let existing = cache.object(forKey: key) {
            Task { @MainActor in
                completion(existing.result)
            }
            return
        }

        let palette = MermaidThemePalette(theme: theme)
        let measurer = self.measurer

        renderQueue.async { [weak self] in
            let result = Self.layoutSync(
                code: code,
                palette: palette,
                measurer: measurer,
                maxWidth: maxWidth
            )
            self?.cache.setObject(MermaidCachedEntry(result: result), forKey: key)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    public static func layoutSync(
        code: String,
        palette: MermaidThemePalette,
        measurer: MermaidTextMeasurer = MermaidCoreTextMeasurer(),
        maxWidth: CGFloat = 760
    ) -> MermaidRenderResult {
        do {
            let layout = try MermaidEngine.parseAndLayout(code, measurer: measurer, maxWidth: maxWidth)
            return .diagram(layout, palette: palette)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    public static func makeZoomAttachment(code: String, theme: Theme) -> AgentImageAttachment? {
        let palette = MermaidThemePalette(theme: theme)
        guard case .diagram(let layout, _) = layoutSync(
            code: code,
            palette: palette,
            maxWidth: 1100
        ),
        let img = MermaidCGContextRenderer.renderImage(
            layout,
            palette: palette,
            scale: 3.0,
            opaqueBackground: theme.background
        ),
        let png = MermaidCGContextRenderer.pngData(from: img) else {
            return nil
        }
        return AgentImageAttachment(
            data: png,
            mimeType: "image/png",
            filename: "mermaid-diagram.png",
            width: Double(layout.size.width),
            height: Double(layout.size.height)
        )
    }
}
