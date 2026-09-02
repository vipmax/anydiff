import Foundation
import AppKit

/// Curated SVG icon resource identifiers for programming languages, frameworks, and configuration files.
public enum Icons {
    public static let typescript = "typescript"
    public static let javascript = "javascript"
    public static let react = "react"
    public static let python = "python"
    public static let rust = "rust"
    public static let go = "go"
    public static let kotlin = "kotlin"
    public static let cplusplus = "cplusplus"
    public static let c = "c"
    public static let csharp = "csharp"
    public static let java = "java"
    public static let html5 = "html5"
    public static let css3 = "css3"
    public static let sass = "sass"
    public static let vue = "vue"
    public static let svelte = "svelte"
    public static let php = "php"
    public static let ruby = "ruby"
    public static let docker = "docker"
    public static let git = "git"
    public static let markdown = "markdown"
    public static let json = "json"
    public static let yaml = "yaml"
    public static let toml = "toml"
    public static let graphql = "graphql"
    public static let sql = "sql"
    public static let shell = "shell"
    public static let npm = "npm"
    public static let yarn = "yarn"
    public static let pnpm = "pnpm"
    public static let bun = "bun"
    public static let eslint = "eslint"
    public static let prettier = "prettier"
    public static let vite = "vite"
    public static let tailwind = "tailwind"
    public static let nextjs = "nextjs"
    public static let astro = "astro"
    public static let prisma = "prisma"
    public static let terraform = "terraform"
    public static let kubernetes = "kubernetes"
    public static let elixir = "elixir"
    public static let scala = "scala"
    public static let haskell = "haskell"
    public static let clojure = "clojure"
    public static let nix = "nix"
    public static let svg = "svg"
    public static let dart = "dart"
    public static let lua = "lua"
    public static let zig = "zig"
    public static let env = "env"

    /// Safely resolves the resource bundle containing icons without triggering SwiftPM fatalError if missing.
    public static let resourceBundle: Bundle? = {
        // 1. Inside App Bundle Resources (Contents/Resources/AnyDiff_AnyDiffUI.bundle)
        if let resourceURL = Bundle.main.resourceURL {
            let bundleURL = resourceURL.appendingPathComponent("AnyDiff_AnyDiffUI.bundle")
            if let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }
        // 2. Main bundle root (AnyDiff.app/AnyDiff_AnyDiffUI.bundle)
        let mainBundleRoot = Bundle.main.bundleURL.appendingPathComponent("AnyDiff_AnyDiffUI.bundle")
        if let bundle = Bundle(url: mainBundleRoot) {
            return bundle
        }
        // 3. Executable directory (for CLI or development binary)
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("AnyDiff_AnyDiffUI.bundle"),
           let bundle = Bundle(url: execDir) {
            return bundle
        }
        // 4. Directly in Bundle.main resources (if resources were flattened into Resources/)
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("typescript.svg").path) {
            return Bundle.main
        }
        // 5. Try Bundle.module (works in SPM development & test environment)
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return nil
        #endif
    }()

    /// Loads the raw SVG data for a given icon name safely.
    public static func svgData(named name: String) -> Data? {
        guard let url = svgURL(named: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Resolves the file URL for an icon name inside resources.
    public static func svgURL(named name: String) -> URL? {
        if let bundle = resourceBundle {
            return bundle.url(forResource: name, withExtension: "svg", subdirectory: "Icons")
                ?? bundle.url(forResource: name, withExtension: "svg")
        }
        return nil
    }
}

