import SwiftUI
import AppKit

// MARK: - Lightweight Icon Loader & Cache

public final class AgentIconLoader: ObservableObject {
    public static let shared = AgentIconLoader()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 100
    }

    public func load(_ source: String, completion: @escaping (NSImage?) -> Void) {
        let key = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { completion(nil); return }

        // 1. Check in-memory cache
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        // 2. Check built-in vector brand icons (offline, 0ms latency)
        if let brandImage = AgentBrandIcons.image(for: key) {
            cache.setObject(brandImage, forKey: key as NSString)
            completion(brandImage)
            return
        }

        // 3. Determine URL (full URL or simple-icons slug)
        let urlString: String
        if key.hasPrefix("http://") || key.hasPrefix("https://") {
            urlString = key
        } else if !key.contains(" ") && !key.contains(".") && !key.contains("/") {
            urlString = "https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/\(key.lowercased()).svg"
        } else {
            completion(nil)
            return
        }

        guard let url = URL(string: urlString) else { completion(nil); return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil,
                  data.count < 100_000,
                  let image = NSImage(data: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            image.isTemplate = true
            self.cache.setObject(image, forKey: key as NSString)
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
}

// MARK: - AgentIconView

public struct AgentIconView: View {
    public let icon: String
    public var tintColor: Color = .primary
    public var size: CGFloat = 20

    @State private var loadedImage: NSImage? = nil

    public init(icon: String, tintColor: Color = .primary, size: CGFloat = 20) {
        self.icon = icon
        self.tintColor = tintColor
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = loadedImage {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(tintColor)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.85, weight: .semibold))
                    .foregroundColor(tintColor)
            }
        }
        .frame(width: size, height: size)
        .onAppear { fetchIcon() }
        .onChange(of: icon) { _ in fetchIcon() }
    }

    private var fallbackSymbol: String {
        switch icon.lowercased() {
        case "openai", "codex": return "sparkles"
        case "googlegemini", "antigravity", "gemini", "google": return "bolt.fill"
        case "claude", "claudecode", "anthropic": return "brain"
        default: return icon.contains("/") || icon.contains(":") ? "cube" : icon
        }
    }

    private func fetchIcon() {
        AgentIconLoader.shared.load(icon) { image in
            self.loadedImage = image
        }
    }
}
