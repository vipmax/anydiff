import Foundation
import AppKit

/// Represents an icon representation for a file based on its extension or specific filename.
public struct FileIcon: Sendable, Equatable {
    public let systemName: String
    public let color: NSColor
    public let languageName: String
    public let iconName: String?
    public let svg: String?

    public init(systemName: String, color: NSColor, languageName: String, iconName: String? = nil, svg: String? = nil) {
        self.systemName = systemName
        self.color = color
        self.languageName = languageName
        self.iconName = iconName
        self.svg = svg
    }

    public init(iconName: String, languageName: String, fallbackSystemName: String = "doc.fill", fallbackColor: NSColor = .tertiaryLabelColor) {
        self.systemName = fallbackSystemName
        self.color = fallbackColor
        self.languageName = languageName
        self.iconName = iconName
        self.svg = nil
    }

    public init(svg: String, languageName: String, fallbackSystemName: String = "doc.fill", fallbackColor: NSColor = .tertiaryLabelColor) {
        self.systemName = fallbackSystemName
        self.color = fallbackColor
        self.languageName = languageName
        self.iconName = svg
        self.svg = svg
    }
}

/// Fast, thread-safe file icon provider with caching for 120 FPS scrolling.
public final class FileIconProvider: @unchecked Sendable {
    public static let shared = FileIconProvider()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 300
    }

    /// Resolves the metadata (symbol/SVG and color) for any file path.
    public static func icon(for filePath: String) -> FileIcon {
        let fileName = (filePath as NSString).lastPathComponent.lowercased()
        let ext = (filePath as NSString).pathExtension.lowercased()

        // 1. Exact filename matches
        switch fileName {
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml", ".dockerignore", "containerfile":
            return FileIcon(svg: Icons.docker, languageName: "Docker")
        case "package.swift":
            return FileIcon(systemName: "swift", color: NSColor(red: 0.98, green: 0.45, blue: 0.26, alpha: 1.0), languageName: "Swift Package")
        case "cargo.toml", "cargo.lock":
            return FileIcon(svg: Icons.toml, languageName: "Cargo")
        case "package.json", "package-lock.json":
            return FileIcon(svg: Icons.npm, languageName: "NPM Package")
        case "yarn.lock", ".yarnrc", ".yarnrc.yml":
            return FileIcon(svg: Icons.yarn, languageName: "Yarn Package")
        case "pnpm-lock.yaml", "pnpm-workspace.yaml", ".pnpmfile.cjs":
            return FileIcon(svg: Icons.pnpm, languageName: "PNPM Package")
        case "bun.lockb", "bun.lock", "bunfig.toml":
            return FileIcon(svg: Icons.bun, languageName: "Bun")
        case ".eslintrc", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.json", ".eslintrc.yaml", ".eslintrc.yml", "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs", "eslint.config.ts", ".eslintignore":
            return FileIcon(svg: Icons.eslint, languageName: "ESLint")
        case ".prettierrc", ".prettierrc.json", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.toml", "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", ".prettierignore":
            return FileIcon(svg: Icons.prettier, languageName: "Prettier")
        case "vite.config.js", "vite.config.ts", "vite.config.mjs", "vite.config.cjs":
            return FileIcon(svg: Icons.vite, languageName: "Vite")
        case "tailwind.config.js", "tailwind.config.ts", "tailwind.config.cjs", "tailwind.config.mjs":
            return FileIcon(svg: Icons.tailwind, languageName: "Tailwind CSS")
        case "next.config.js", "next.config.mjs", "next.config.ts":
            return FileIcon(svg: Icons.nextjs, languageName: "Next.js")
        case "astro.config.mjs", "astro.config.ts", "astro.config.js", "astro.config.cjs":
            return FileIcon(svg: Icons.astro, languageName: "Astro")
        case "svelte.config.js", "svelte.config.ts":
            return FileIcon(svg: Icons.svelte, languageName: "Svelte")
        case "schema.prisma":
            return FileIcon(svg: Icons.prisma, languageName: "Prisma")
        case "makefile", "gnumakefile", "justfile", "rakefile", "cmakelists.txt":
            return FileIcon(systemName: "hammer.fill", color: NSColor(red: 0.90, green: 0.55, blue: 0.20, alpha: 1.0), languageName: "Build Config")
        case ".gitignore", ".gitmodules", ".gitattributes", ".gitconfig":
            return FileIcon(svg: Icons.git, languageName: "Git")
        case ".env", ".env.local", ".env.production", ".env.development", ".env.example", ".env.test":
            return FileIcon(svg: Icons.env, languageName: "Environment")
        case "readme", "readme.md", "readme.txt":
            return FileIcon(svg: Icons.markdown, languageName: "Readme")
        case "license", "license.md", "license.txt", "licence", "licence.md", "licence.txt":
            return FileIcon(systemName: "doc.text.fill", color: NSColor.systemOrange, languageName: "License")
        case "tsconfig.json", "jsconfig.json":
            return FileIcon(svg: Icons.typescript, languageName: "TypeScript Config")
        case "podfile", "podfile.lock":
            return FileIcon(systemName: "leaf.fill", color: NSColor(red: 0.93, green: 0.20, blue: 0.13, alpha: 1.0), languageName: "CocoaPods")
        case "gemfile", "gemfile.lock":
            return FileIcon(svg: Icons.ruby, languageName: "RubyGems")
        case "requirements.txt", "pyproject.toml", "pipfile", "pipfile.lock", "poetry.lock", "setup.py":
            return FileIcon(svg: Icons.python, languageName: "Python Package")
        case "go.mod", "go.sum", "go.work":
            return FileIcon(svg: Icons.go, languageName: "Go Module")
        case "mix.exs", "mix.lock":
            return FileIcon(svg: Icons.elixir, languageName: "Elixir Mix")
        case "build.sbt":
            return FileIcon(svg: Icons.scala, languageName: "SBT")
        case "flake.nix", "flake.lock":
            return FileIcon(svg: Icons.nix, languageName: "Nix Flake")
        case "k8s.yaml", "k8s.yml", "chart.yaml", "values.yaml":
            return FileIcon(svg: Icons.kubernetes, languageName: "Kubernetes")
        default:
            break
        }

        // 2. Extension matches
        switch ext {
        case "ts", "mts", "cts":
            return FileIcon(svg: Icons.typescript, languageName: "TypeScript")
        case "tsx":
            return FileIcon(svg: Icons.react, languageName: "React TypeScript")
        case "js", "mjs", "cjs":
            return FileIcon(svg: Icons.javascript, languageName: "JavaScript")
        case "jsx":
            return FileIcon(svg: Icons.react, languageName: "React JavaScript")
        case "swift":
            return FileIcon(systemName: "swift", color: NSColor(red: 0.98, green: 0.45, blue: 0.26, alpha: 1.0), languageName: "Swift")
        case "rs":
            return FileIcon(svg: Icons.rust, languageName: "Rust")
        case "py", "pyi", "pyw", "ipynb":
            return FileIcon(svg: Icons.python, languageName: "Python")
        case "go":
            return FileIcon(svg: Icons.go, languageName: "Go")
        case "c", "h":
            return FileIcon(svg: Icons.c, languageName: "C")
        case "cpp", "hpp", "cc", "cxx", "hxx", "c++", "h++":
            return FileIcon(svg: Icons.cplusplus, languageName: "C++")
        case "m", "mm":
            return FileIcon(systemName: "apple.logo", color: NSColor(red: 0.26, green: 0.56, blue: 1.0, alpha: 1.0), languageName: "Objective-C")
        case "java", "jar":
            return FileIcon(svg: Icons.java, languageName: "Java")
        case "kt", "kts":
            return FileIcon(svg: Icons.kotlin, languageName: "Kotlin")
        case "cs", "csx", "csproj", "sln":
            return FileIcon(svg: Icons.csharp, languageName: "C#")
        case "rb", "erb", "gemspec":
            return FileIcon(svg: Icons.ruby, languageName: "Ruby")
        case "php":
            return FileIcon(svg: Icons.php, languageName: "PHP")
        case "html", "htm":
            return FileIcon(svg: Icons.html5, languageName: "HTML")
        case "css":
            return FileIcon(svg: Icons.css3, languageName: "CSS")
        case "scss", "sass", "less":
            return FileIcon(svg: Icons.sass, languageName: "CSS")
        case "vue":
            return FileIcon(svg: Icons.vue, languageName: "Vue")
        case "svelte":
            return FileIcon(svg: Icons.svelte, languageName: "Svelte")
        case "astro":
            return FileIcon(svg: Icons.astro, languageName: "Astro")
        case "prisma":
            return FileIcon(svg: Icons.prisma, languageName: "Prisma")
        case "tf", "tfvars":
            return FileIcon(svg: Icons.terraform, languageName: "Terraform")
        case "ex", "exs":
            return FileIcon(svg: Icons.elixir, languageName: "Elixir")
        case "scala", "sc":
            return FileIcon(svg: Icons.scala, languageName: "Scala")
        case "hs", "lhs":
            return FileIcon(svg: Icons.haskell, languageName: "Haskell")
        case "clj", "cljs", "cljc", "edn":
            return FileIcon(svg: Icons.clojure, languageName: "Clojure")
        case "nix":
            return FileIcon(svg: Icons.nix, languageName: "Nix")
        case "json", "json5", "jsonc":
            return FileIcon(svg: Icons.json, languageName: "JSON")
        case "yaml", "yml":
            return FileIcon(svg: Icons.yaml, languageName: "YAML")
        case "toml":
            return FileIcon(svg: Icons.toml, languageName: "TOML")
        case "xml", "plist", "config", "ini", "props":
            return FileIcon(systemName: "doc.badge.gearshape.fill", color: NSColor.secondaryLabelColor, languageName: "Config/XML")
        case "md", "markdown", "mdx", "rst":
            return FileIcon(svg: Icons.markdown, languageName: "Markdown")
        case "txt", "text", "log":
            return FileIcon(systemName: "doc.text.fill", color: NSColor.secondaryLabelColor, languageName: "Plain Text")
        case "sh", "bash", "zsh", "fish", "command":
            return FileIcon(svg: Icons.shell, languageName: "Shell")
        case "sql", "sqlite", "db":
            return FileIcon(svg: Icons.sql, languageName: "SQL")
        case "graphql", "gql":
            return FileIcon(svg: Icons.graphql, languageName: "GraphQL")
        case "dart":
            return FileIcon(svg: Icons.dart, languageName: "Dart")
        case "lua":
            return FileIcon(svg: Icons.lua, languageName: "Lua")
        case "zig":
            return FileIcon(svg: Icons.zig, languageName: "Zig")
        case "svg":
            return FileIcon(svg: Icons.svg, languageName: "SVG")
        case "pdf":
            return FileIcon(systemName: "doc.richtext.fill", color: NSColor.systemRed, languageName: "PDF")
        case "csv", "tsv":
            return FileIcon(systemName: "tablecells.fill", color: NSColor.systemGreen, languageName: "Spreadsheet")
        case "proto":
            return FileIcon(systemName: "hexagon.fill", color: NSColor.systemTeal, languageName: "Protobuf")
        case "http", "rest":
            return FileIcon(systemName: "network", color: NSColor.systemTeal, languageName: "HTTP")
        case "png", "jpg", "jpeg", "gif", "webp", "ico", "icns", "bmp", "tiff":
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
        let iconKey = iconInfo.iconName ?? iconInfo.svg ?? iconInfo.systemName
        let key = "\(iconInfo.languageName)_\(iconKey)_\(iconInfo.color.description)_\(pointSize)_\(weight.rawValue)" as NSString

        if let cached = cache.object(forKey: key) {
            return cached
        }

        // 1. Try vector SVG from resource file (Bundle.module) first
        if let iconName = iconInfo.iconName,
           let data = Icons.svgData(named: iconName),
           let svgImage = NSImage(data: data) {
            svgImage.size = NSSize(width: pointSize, height: pointSize)
            cache.setObject(svgImage, forKey: key)
            return svgImage
        }

        // 2. Fallback to inline SVG string if provided
        if let svg = iconInfo.svg,
           let data = svg.data(using: .utf8),
           let svgImage = NSImage(data: data) {
            svgImage.size = NSSize(width: pointSize, height: pointSize)
            cache.setObject(svgImage, forKey: key)
            return svgImage
        }

        // 3. Fallback to SF Symbol with configured palette color
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
