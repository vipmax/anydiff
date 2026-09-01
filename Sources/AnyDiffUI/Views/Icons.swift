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

    /// Loads the raw SVG data for a given icon name from Bundle.module.
    public static func svgData(named name: String) -> Data? {
        guard let url = svgURL(named: name) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Resolves the file URL for an icon name inside Bundle.module resources.
    public static func svgURL(named name: String) -> URL? {
        return Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
    }
}

