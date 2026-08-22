import Foundation
import AppKit

/// Represents an icon representation for a file based on its extension or specific filename.
public struct FileIcon: Sendable, Equatable {
    public let systemName: String
    public let color: NSColor
    public let languageName: String

    public init(systemName: String, color: NSColor, languageName: String) {
        self.systemName = systemName
        self.color = color
        self.languageName = languageName
    }
}

/// Fast, thread-safe file icon provider with caching for 120 FPS scrolling.
public final class FileIconProvider: @unchecked Sendable {
    public static let shared = FileIconProvider()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    /// Resolves the metadata (symbol and color) for any file path.
    public static func icon(for filePath: String) -> FileIcon {
        let fileName = (filePath as NSString).lastPathComponent.lowercased()
        let ext = (filePath as NSString).pathExtension.lowercased()

        // 1. Exact filename matches
        switch fileName {
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml", ".dockerignore", "containerfile":
            return FileIcon(systemName: "shippingbox.fill", color: NSColor(red: 0.14, green: 0.59, blue: 0.93, alpha: 1.0), languageName: "Docker")
        case "package.swift":
            return FileIcon(systemName: "swift", color: NSColor(red: 0.94, green: 0.32, blue: 0.22, alpha: 1.0), languageName: "Swift Package")
        case "cargo.toml", "cargo.lock":
            return FileIcon(systemName: "shippingbox.fill", color: NSColor(red: 0.81, green: 0.25, blue: 0.17, alpha: 1.0), languageName: "Cargo")
        case "package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb":
            return FileIcon(systemName: "cube.box.fill", color: NSColor(red: 0.45, green: 0.72, blue: 0.32, alpha: 1.0), languageName: "NPM Package")
        case "makefile", "gnumakefile", "justfile", "rakefile", "cmakelists.txt":
            return FileIcon(systemName: "hammer.fill", color: NSColor(red: 0.90, green: 0.55, blue: 0.20, alpha: 1.0), languageName: "Build Config")
        case ".gitignore", ".gitmodules", ".gitattributes":
            return FileIcon(systemName: "arrow.triangle.branch", color: NSColor(red: 0.94, green: 0.31, blue: 0.20, alpha: 1.0), languageName: "Git")
        case ".env", ".env.local", ".env.production", ".env.development", ".env.example":
            return FileIcon(systemName: "key.fill", color: NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1.0), languageName: "Environment")
        case "readme", "readme.md", "readme.txt":
            return FileIcon(systemName: "info.circle.fill", color: NSColor.systemIndigo, languageName: "Readme")
        case "license", "license.md", "license.txt":
            return FileIcon(systemName: "doc.text.fill", color: NSColor.systemOrange, languageName: "License")
        case "tsconfig.json", "jsconfig.json":
            return FileIcon(systemName: "gearshape.fill", color: NSColor(red: 0.19, green: 0.47, blue: 0.78, alpha: 1.0), languageName: "TypeScript Config")
        case "podfile", "podfile.lock":
            return FileIcon(systemName: "leaf.fill", color: NSColor(red: 0.93, green: 0.20, blue: 0.13, alpha: 1.0), languageName: "CocoaPods")
        case "gemfile", "gemfile.lock":
            return FileIcon(systemName: "diamond.fill", color: NSColor(red: 0.80, green: 0.20, blue: 0.18, alpha: 1.0), languageName: "RubyGems")
        case "requirements.txt", "pyproject.toml", "pipfile", "setup.py":
            return FileIcon(systemName: "shippingbox.fill", color: NSColor(red: 0.22, green: 0.46, blue: 0.67, alpha: 1.0), languageName: "Python Package")
        case "go.mod", "go.sum":
            return FileIcon(systemName: "cube.box.fill", color: NSColor(red: 0.0, green: 0.68, blue: 0.85, alpha: 1.0), languageName: "Go Module")
        default:
            break
        }

        // 2. Extension matches
        switch ext {
        case "swift":
            return FileIcon(systemName: "swift", color: NSColor(red: 0.94, green: 0.32, blue: 0.22, alpha: 1.0), languageName: "Swift")
        case "rs":
            return FileIcon(systemName: "gearshape.2.fill", color: NSColor(red: 0.81, green: 0.25, blue: 0.17, alpha: 1.0), languageName: "Rust")
        case "ts", "mts", "cts":
            return FileIcon(systemName: "curlybraces", color: NSColor(red: 0.19, green: 0.47, blue: 0.78, alpha: 1.0), languageName: "TypeScript")
        case "tsx":
            return FileIcon(systemName: "atom", color: NSColor(red: 0.38, green: 0.85, blue: 0.98, alpha: 1.0), languageName: "React TypeScript")
        case "js", "mjs", "cjs":
            return FileIcon(systemName: "curlybraces", color: NSColor(red: 0.95, green: 0.80, blue: 0.15, alpha: 1.0), languageName: "JavaScript")
        case "jsx":
            return FileIcon(systemName: "atom", color: NSColor(red: 0.38, green: 0.85, blue: 0.98, alpha: 1.0), languageName: "React JavaScript")
        case "py", "pyi", "pyw", "ipynb":
            return FileIcon(systemName: "chevron.left.forwardslash.chevron.right", color: NSColor(red: 0.22, green: 0.46, blue: 0.67, alpha: 1.0), languageName: "Python")
        case "go":
            return FileIcon(systemName: "arrow.right.circle.fill", color: NSColor(red: 0.0, green: 0.68, blue: 0.85, alpha: 1.0), languageName: "Go")
        case "c", "h":
            return FileIcon(systemName: "c.square.fill", color: NSColor(red: 0.40, green: 0.45, blue: 0.55, alpha: 1.0), languageName: "C")
        case "cpp", "hpp", "cc", "cxx", "hxx":
            return FileIcon(systemName: "c.square.fill", color: NSColor(red: 0.0, green: 0.42, blue: 0.70, alpha: 1.0), languageName: "C++")
        case "m", "mm":
            return FileIcon(systemName: "apple.logo", color: NSColor(red: 0.26, green: 0.56, blue: 1.0, alpha: 1.0), languageName: "Objective-C")
        case "java", "jar":
            return FileIcon(systemName: "cup.and.saucer.fill", color: NSColor(red: 0.90, green: 0.43, blue: 0.0, alpha: 1.0), languageName: "Java")
        case "kt", "kts":
            return FileIcon(systemName: "k.square.fill", color: NSColor(red: 0.50, green: 0.32, blue: 1.0, alpha: 1.0), languageName: "Kotlin")
        case "cs", "csx", "csproj", "sln":
            return FileIcon(systemName: "number.square.fill", color: NSColor(red: 0.41, green: 0.13, blue: 0.48, alpha: 1.0), languageName: "C#")
        case "rb", "erb", "gemspec":
            return FileIcon(systemName: "diamond.fill", color: NSColor(red: 0.80, green: 0.20, blue: 0.18, alpha: 1.0), languageName: "Ruby")
        case "php":
            return FileIcon(systemName: "chevron.left.forwardslash.chevron.right", color: NSColor(red: 0.47, green: 0.48, blue: 0.71, alpha: 1.0), languageName: "PHP")
        case "html", "htm":
            return FileIcon(systemName: "chevron.left.forwardslash.chevron.right", color: NSColor(red: 0.89, green: 0.31, blue: 0.15, alpha: 1.0), languageName: "HTML")
        case "css", "scss", "sass", "less":
            return FileIcon(systemName: "paintbrush.fill", color: NSColor(red: 0.08, green: 0.45, blue: 0.71, alpha: 1.0), languageName: "CSS")
        case "json", "json5", "jsonc":
            return FileIcon(systemName: "curlybraces.square.fill", color: NSColor(red: 0.85, green: 0.75, blue: 0.20, alpha: 1.0), languageName: "JSON")
        case "yaml", "yml":
            return FileIcon(systemName: "list.bullet.rectangle", color: NSColor(red: 0.80, green: 0.10, blue: 0.12, alpha: 1.0), languageName: "YAML")
        case "toml":
            return FileIcon(systemName: "slider.horizontal.3", color: NSColor(red: 0.61, green: 0.26, blue: 0.13, alpha: 1.0), languageName: "TOML")
        case "xml", "plist", "config", "ini", "props":
            return FileIcon(systemName: "doc.badge.gearshape.fill", color: NSColor.secondaryLabelColor, languageName: "Config/XML")
        case "md", "markdown", "mdx", "rst", "txt":
            return FileIcon(systemName: "doc.text.fill", color: NSColor.secondaryLabelColor, languageName: "Markdown")
        case "sh", "bash", "zsh", "fish", "command":
            return FileIcon(systemName: "terminal.fill", color: NSColor(red: 0.31, green: 0.67, blue: 0.15, alpha: 1.0), languageName: "Shell")
        case "sql", "sqlite", "db", "prisma":
            return FileIcon(systemName: "cylinder.split.1x2.fill", color: NSColor(red: 0.20, green: 0.40, blue: 0.57, alpha: 1.0), languageName: "SQL")
        case "graphql", "gql":
            return FileIcon(systemName: "rhombus.fill", color: NSColor(red: 0.88, green: 0.0, blue: 0.60, alpha: 1.0), languageName: "GraphQL")
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "icns", "bmp", "tiff":
            return FileIcon(systemName: "photo.fill", color: NSColor.systemPurple, languageName: "Image")
        case "mp3", "wav", "ogg", "flac", "mp4", "mov", "mkv", "avi", "webm":
            return FileIcon(systemName: "play.rectangle.fill", color: NSColor.systemRed, languageName: "Media")
        case "ttf", "otf", "woff", "woff2", "eot":
            return FileIcon(systemName: "textformat", color: NSColor.systemBrown, languageName: "Font")
        case "zip", "tar", "gz", "7z", "rar", "dmg", "pkg":
            return FileIcon(systemName: "archivebox.fill", color: NSColor.systemOrange, languageName: "Archive")
        case "lock":
            return FileIcon(systemName: "lock.fill", color: NSColor.tertiaryLabelColor, languageName: "Lockfile")
        case "diff", "patch":
            return FileIcon(systemName: "arrow.left.and.right.square.fill", color: NSColor.systemTeal, languageName: "Diff")
        default:
            return FileIcon(systemName: "doc.fill", color: NSColor.tertiaryLabelColor, languageName: "Plain Text")
        }
    }

    /// Returns a cached, properly configured and colored NSImage for the given file path.
    public func image(for filePath: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage {
        let iconInfo = Self.icon(for: filePath)
        let key = "\(iconInfo.systemName)_\(iconInfo.color.description)_\(pointSize)_\(weight.rawValue)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            .applying(.init(paletteColors: [iconInfo.color]))

        var image: NSImage?
        if let symImg = NSImage(systemSymbolName: iconInfo.systemName, accessibilityDescription: iconInfo.languageName)?
            .withSymbolConfiguration(config) {
            image = symImg
        } else if let fallbackImg = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: "File")?
            .withSymbolConfiguration(config) {
            image = fallbackImg
        } else {
            image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        }

        let finalImage = image ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        cache.setObject(finalImage, forKey: key)
        return finalImage
    }
}
