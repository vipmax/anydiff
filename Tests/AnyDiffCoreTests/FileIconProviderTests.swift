import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

final class FileIconProviderTests: XCTestCase {
    func testKnownLanguageExtensions() {
        XCTAssertEqual(FileIconProvider.icon(for: "Sources/main.swift").languageName, "Swift")
        XCTAssertEqual(FileIconProvider.icon(for: "src/lib.rs").languageName, "Rust")
        XCTAssertEqual(FileIconProvider.icon(for: "index.ts").languageName, "TypeScript")
        XCTAssertEqual(FileIconProvider.icon(for: "App.tsx").languageName, "React TypeScript")
        XCTAssertEqual(FileIconProvider.icon(for: "script.js").languageName, "JavaScript")
        XCTAssertEqual(FileIconProvider.icon(for: "Component.jsx").languageName, "React JavaScript")
        XCTAssertEqual(FileIconProvider.icon(for: "server.py").languageName, "Python")
        XCTAssertEqual(FileIconProvider.icon(for: "main.go").languageName, "Go")
        XCTAssertEqual(FileIconProvider.icon(for: "main.c").languageName, "C")
        XCTAssertEqual(FileIconProvider.icon(for: "main.cpp").languageName, "C++")
        XCTAssertEqual(FileIconProvider.icon(for: "Main.java").languageName, "Java")
        XCTAssertEqual(FileIconProvider.icon(for: "Main.kt").languageName, "Kotlin")
        XCTAssertEqual(FileIconProvider.icon(for: "Program.cs").languageName, "C#")
        XCTAssertEqual(FileIconProvider.icon(for: "app.rb").languageName, "Ruby")
        XCTAssertEqual(FileIconProvider.icon(for: "index.php").languageName, "PHP")
        XCTAssertEqual(FileIconProvider.icon(for: "index.html").languageName, "HTML")
        XCTAssertEqual(FileIconProvider.icon(for: "styles.css").languageName, "CSS")
        XCTAssertEqual(FileIconProvider.icon(for: "data.json").languageName, "JSON")
        XCTAssertEqual(FileIconProvider.icon(for: "config.yaml").languageName, "YAML")
        XCTAssertEqual(FileIconProvider.icon(for: "Cargo.toml").languageName, "Cargo")
        XCTAssertEqual(FileIconProvider.icon(for: "other.toml").languageName, "TOML")
        XCTAssertEqual(FileIconProvider.icon(for: "README.md").languageName, "Readme")
        XCTAssertEqual(FileIconProvider.icon(for: "notes.txt").languageName, "Markdown")
        XCTAssertEqual(FileIconProvider.icon(for: "deploy.sh").languageName, "Shell")
        XCTAssertEqual(FileIconProvider.icon(for: "query.sql").languageName, "SQL")
        XCTAssertEqual(FileIconProvider.icon(for: "schema.graphql").languageName, "GraphQL")
        XCTAssertEqual(FileIconProvider.icon(for: "icon.png").languageName, "Image")
        XCTAssertEqual(FileIconProvider.icon(for: "archive.zip").languageName, "Archive")
    }

    func testExactFilenameMatches() {
        XCTAssertEqual(FileIconProvider.icon(for: "Dockerfile").languageName, "Docker")
        XCTAssertEqual(FileIconProvider.icon(for: "docker-compose.yml").languageName, "Docker")
        XCTAssertEqual(FileIconProvider.icon(for: "Package.swift").languageName, "Swift Package")
        XCTAssertEqual(FileIconProvider.icon(for: "package.json").languageName, "NPM Package")
        XCTAssertEqual(FileIconProvider.icon(for: "Makefile").languageName, "Build Config")
        XCTAssertEqual(FileIconProvider.icon(for: ".gitignore").languageName, "Git")
        XCTAssertEqual(FileIconProvider.icon(for: ".env").languageName, "Environment")
        XCTAssertEqual(FileIconProvider.icon(for: "LICENSE").languageName, "License")
        XCTAssertEqual(FileIconProvider.icon(for: "tsconfig.json").languageName, "TypeScript Config")
    }

    func testUnknownExtensionFallback() {
        let icon = FileIconProvider.icon(for: "unknown.xyz123")
        XCTAssertEqual(icon.languageName, "Plain Text")
        XCTAssertEqual(icon.systemName, "doc.fill")
    }

    func testImageGenerationAndCaching() {
        let img1 = FileIconProvider.shared.image(for: "main.swift", pointSize: 13)
        let img2 = FileIconProvider.shared.image(for: "other.swift", pointSize: 13)
        XCTAssertNotNil(img1)
        XCTAssertNotNil(img2)
        XCTAssertEqual(img1, img2, "Cached NSImage should be reused for identical symbol, color, and size")

        let tsIcon = FileIconProvider.icon(for: "App.ts")
        XCTAssertEqual(tsIcon.languageName, "TypeScript")
        XCTAssertNotNil(tsIcon.iconName ?? tsIcon.svg)

        let tsImg = FileIconProvider.shared.image(for: "App.ts", pointSize: 13)
        XCTAssertNotNil(tsImg)
        XCTAssertEqual(tsImg.size.width, 13)
        XCTAssertEqual(tsImg.size.height, 13)
    }

    func testBundleModuleSVGLoading() {
        let testFiles = ["main.rs", "server.py", "app.go", "Dockerfile", "data.json", "styles.css", "icon.svg"]
        for file in testFiles {
            let icon = FileIconProvider.icon(for: file)
            XCTAssertNotNil(icon.iconName ?? icon.svg, "Expected SVG icon for \(file)")
            let img = FileIconProvider.shared.image(for: file, pointSize: 14)
            XCTAssertNotNil(img, "Expected NSImage for \(file)")
            XCTAssertEqual(img.size.width, 14, "Expected 14pt width for \(file)")
            XCTAssertEqual(img.size.height, 14, "Expected 14pt height for \(file)")
        }
    }
}

