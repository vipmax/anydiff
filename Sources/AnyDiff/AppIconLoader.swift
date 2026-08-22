import AppKit

final class AppIconLoader {
    private var cachedIcon: NSImage?

    func load() -> NSImage? {
        if let cachedIcon {
            return cachedIcon
        }

        // 1. Standard bundle resource (when running inside AnyDiff.app)
        if let image = Bundle.main.image(forResource: "AppIcon") {
            cachedIcon = image
            return image
        }
        if let resourceURL = Bundle.main.resourceURL {
            let pngURL = resourceURL.appendingPathComponent("AppIcon.png")
            if let image = NSImage(contentsOf: pngURL) {
                cachedIcon = image
                return image
            }
            let icnsURL = resourceURL.appendingPathComponent("AppIcon.icns")
            if let image = NSImage(contentsOf: icnsURL) {
                cachedIcon = image
                return image
            }
        }

        // 2. Development mode (swift run / just release / just dev) via #filePath
        let sourceURL = URL(fileURLWithPath: #filePath)
        let projectRoot = sourceURL
            .deletingLastPathComponent() // AnyDiff
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Project root
        let devIconURL = projectRoot.appendingPathComponent("Resources/AppIcon.png")
        if let image = NSImage(contentsOf: devIconURL) {
            cachedIcon = image
            return image
        }

        // 3. Fallback to current working directory
        let cwdIconURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/AppIcon.png")
        if let image = NSImage(contentsOf: cwdIconURL) {
            cachedIcon = image
            return image
        }

        return nil
    }
}
