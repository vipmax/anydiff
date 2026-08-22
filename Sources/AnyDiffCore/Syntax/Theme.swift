import Foundation
import AppKit

/// Color palette for code highlighting, diff gutters, and editor UI
public struct Theme: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let isDark: Bool

    // Editor Backgrounds
    public let background: NSColor
    public let gutterBackground: NSColor
    public let currentLineBackground: NSColor
    public let selectionBackground: NSColor
    public let excerptHeaderBackground: NSColor
    public let excerptHeaderBorder: NSColor

    // Text & Gutter
    public let foreground: NSColor
    public let gutterForeground: NSColor
    public let gutterActiveForeground: NSColor
    public let foldPlaceholderForeground: NSColor

    // Syntax Tokens
    public let keyword: NSColor
    public let type: NSColor
    public let function: NSColor
    public let string: NSColor
    public let number: NSColor
    public let comment: NSColor
    public let property: NSColor
    public let `operator`: NSColor
    public let punctuation: NSColor

    // Diff Colors
    public let diffAddedGutter: NSColor
    public let diffAddedBackground: NSColor
    public let diffAddedWordHighlight: NSColor

    public let diffDeletedGutter: NSColor
    public let diffDeletedBackground: NSColor
    public let diffDeletedWordHighlight: NSColor

    public let diffModifiedGutter: NSColor

    public init(
        id: String,
        name: String,
        isDark: Bool,
        background: NSColor,
        gutterBackground: NSColor,
        currentLineBackground: NSColor,
        selectionBackground: NSColor,
        excerptHeaderBackground: NSColor,
        excerptHeaderBorder: NSColor,
        foreground: NSColor,
        gutterForeground: NSColor,
        gutterActiveForeground: NSColor,
        foldPlaceholderForeground: NSColor,
        keyword: NSColor,
        type: NSColor,
        function: NSColor,
        string: NSColor,
        number: NSColor,
        comment: NSColor,
        property: NSColor,
        operator: NSColor,
        punctuation: NSColor,
        diffAddedGutter: NSColor,
        diffAddedBackground: NSColor,
        diffAddedWordHighlight: NSColor,
        diffDeletedGutter: NSColor,
        diffDeletedBackground: NSColor,
        diffDeletedWordHighlight: NSColor,
        diffModifiedGutter: NSColor
    ) {
        self.id = id
        self.name = name
        self.isDark = isDark
        self.background = background
        self.gutterBackground = gutterBackground
        self.currentLineBackground = currentLineBackground
        self.selectionBackground = selectionBackground
        self.excerptHeaderBackground = excerptHeaderBackground
        self.excerptHeaderBorder = excerptHeaderBorder
        self.foreground = foreground
        self.gutterForeground = gutterForeground
        self.gutterActiveForeground = gutterActiveForeground
        self.foldPlaceholderForeground = foldPlaceholderForeground
        self.keyword = keyword
        self.type = type
        self.function = function
        self.string = string
        self.number = number
        self.comment = comment
        self.property = property
        self.operator = `operator`
        self.punctuation = punctuation
        self.diffAddedGutter = diffAddedGutter
        self.diffAddedBackground = diffAddedBackground
        self.diffAddedWordHighlight = diffAddedWordHighlight
        self.diffDeletedGutter = diffDeletedGutter
        self.diffDeletedBackground = diffDeletedBackground
        self.diffDeletedWordHighlight = diffDeletedWordHighlight
        self.diffModifiedGutter = diffModifiedGutter
    }

    // MARK: - Built-in Themes

    public static let zedDark = Theme(
        id: "zed-dark",
        name: "Zed Dark",
        isDark: true,
        background: NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0),
        gutterBackground: NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1.0),
        currentLineBackground: NSColor(red: 0.15, green: 0.16, blue: 0.19, alpha: 1.0),
        selectionBackground: NSColor(red: 0.22, green: 0.28, blue: 0.40, alpha: 0.7),
        excerptHeaderBackground: NSColor(red: 0.14, green: 0.15, blue: 0.18, alpha: 1.0),
        excerptHeaderBorder: NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1.0),
        foreground: NSColor(red: 0.85, green: 0.87, blue: 0.90, alpha: 1.0),
        gutterForeground: NSColor(red: 0.40, green: 0.44, blue: 0.50, alpha: 1.0),
        gutterActiveForeground: NSColor(red: 0.80, green: 0.85, blue: 0.95, alpha: 1.0),
        foldPlaceholderForeground: NSColor(red: 0.50, green: 0.55, blue: 0.65, alpha: 1.0),
        keyword: NSColor(red: 0.91, green: 0.47, blue: 0.56, alpha: 1.0),
        type: NSColor(red: 0.92, green: 0.76, blue: 0.50, alpha: 1.0),
        function: NSColor(red: 0.40, green: 0.68, blue: 0.95, alpha: 1.0),
        string: NSColor(red: 0.58, green: 0.82, blue: 0.54, alpha: 1.0),
        number: NSColor(red: 0.85, green: 0.60, blue: 0.40, alpha: 1.0),
        comment: NSColor(red: 0.45, green: 0.50, blue: 0.58, alpha: 1.0),
        property: NSColor(red: 0.70, green: 0.80, blue: 0.95, alpha: 1.0),
        operator: NSColor(red: 0.50, green: 0.75, blue: 0.85, alpha: 1.0),
        punctuation: NSColor(red: 0.65, green: 0.70, blue: 0.78, alpha: 1.0),
        diffAddedGutter: NSColor(red: 0.25, green: 0.75, blue: 0.40, alpha: 1.0),
        diffAddedBackground: NSColor(red: 0.18, green: 0.38, blue: 0.22, alpha: 0.25),
        diffAddedWordHighlight: NSColor(red: 0.20, green: 0.60, blue: 0.30, alpha: 0.45),
        diffDeletedGutter: NSColor(red: 0.90, green: 0.30, blue: 0.35, alpha: 1.0),
        diffDeletedBackground: NSColor(red: 0.45, green: 0.18, blue: 0.20, alpha: 0.25),
        diffDeletedWordHighlight: NSColor(red: 0.75, green: 0.20, blue: 0.25, alpha: 0.45),
        diffModifiedGutter: NSColor(red: 0.35, green: 0.65, blue: 0.95, alpha: 1.0)
    )

    public static let tokyoNight = Theme(
        id: "tokyo-night",
        name: "Tokyo Night",
        isDark: true,
        background: NSColor(red: 0.10, green: 0.11, blue: 0.18, alpha: 1.0),
        gutterBackground: NSColor(red: 0.08, green: 0.09, blue: 0.15, alpha: 1.0),
        currentLineBackground: NSColor(red: 0.16, green: 0.18, blue: 0.27, alpha: 1.0),
        selectionBackground: NSColor(red: 0.24, green: 0.28, blue: 0.45, alpha: 0.7),
        excerptHeaderBackground: NSColor(red: 0.13, green: 0.14, blue: 0.23, alpha: 1.0),
        excerptHeaderBorder: NSColor(red: 0.22, green: 0.25, blue: 0.38, alpha: 1.0),
        foreground: NSColor(red: 0.75, green: 0.80, blue: 0.95, alpha: 1.0),
        gutterForeground: NSColor(red: 0.35, green: 0.38, blue: 0.52, alpha: 1.0),
        gutterActiveForeground: NSColor(red: 0.70, green: 0.75, blue: 0.95, alpha: 1.0),
        foldPlaceholderForeground: NSColor(red: 0.50, green: 0.55, blue: 0.70, alpha: 1.0),
        keyword: NSColor(red: 0.73, green: 0.46, blue: 0.98, alpha: 1.0),
        type: NSColor(red: 0.16, green: 0.78, blue: 0.94, alpha: 1.0),
        function: NSColor(red: 0.49, green: 0.69, blue: 0.99, alpha: 1.0),
        string: NSColor(red: 0.59, green: 0.86, blue: 0.45, alpha: 1.0),
        number: NSColor(red: 1.00, green: 0.62, blue: 0.39, alpha: 1.0),
        comment: NSColor(red: 0.36, green: 0.40, blue: 0.58, alpha: 1.0),
        property: NSColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 1.0),
        operator: NSColor(red: 0.54, green: 0.70, blue: 0.95, alpha: 1.0),
        punctuation: NSColor(red: 0.65, green: 0.70, blue: 0.85, alpha: 1.0),
        diffAddedGutter: NSColor(red: 0.45, green: 0.80, blue: 0.45, alpha: 1.0),
        diffAddedBackground: NSColor(red: 0.20, green: 0.40, blue: 0.25, alpha: 0.25),
        diffAddedWordHighlight: NSColor(red: 0.30, green: 0.65, blue: 0.35, alpha: 0.45),
        diffDeletedGutter: NSColor(red: 0.95, green: 0.35, blue: 0.40, alpha: 1.0),
        diffDeletedBackground: NSColor(red: 0.48, green: 0.18, blue: 0.22, alpha: 0.25),
        diffDeletedWordHighlight: NSColor(red: 0.80, green: 0.22, blue: 0.28, alpha: 0.45),
        diffModifiedGutter: NSColor(red: 0.40, green: 0.70, blue: 0.95, alpha: 1.0)
    )

    public static let githubDark = Theme(
        id: "github-dark",
        name: "GitHub Dark",
        isDark: true,
        background: NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1.0),
        gutterBackground: NSColor(red: 0.04, green: 0.06, blue: 0.08, alpha: 1.0),
        currentLineBackground: NSColor(red: 0.10, green: 0.13, blue: 0.16, alpha: 1.0),
        selectionBackground: NSColor(red: 0.18, green: 0.30, blue: 0.48, alpha: 0.7),
        excerptHeaderBackground: NSColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1.0),
        excerptHeaderBorder: NSColor(red: 0.18, green: 0.22, blue: 0.26, alpha: 1.0),
        foreground: NSColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1.0),
        gutterForeground: NSColor(red: 0.40, green: 0.44, blue: 0.50, alpha: 1.0),
        gutterActiveForeground: NSColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1.0),
        foldPlaceholderForeground: NSColor(red: 0.50, green: 0.55, blue: 0.65, alpha: 1.0),
        keyword: NSColor(red: 1.00, green: 0.48, blue: 0.52, alpha: 1.0),
        type: NSColor(red: 1.00, green: 0.65, blue: 0.35, alpha: 1.0),
        function: NSColor(red: 0.85, green: 0.60, blue: 1.00, alpha: 1.0),
        string: NSColor(red: 0.64, green: 0.85, blue: 1.00, alpha: 1.0),
        number: NSColor(red: 0.45, green: 0.80, blue: 1.00, alpha: 1.0),
        comment: NSColor(red: 0.48, green: 0.54, blue: 0.60, alpha: 1.0),
        property: NSColor(red: 0.48, green: 0.78, blue: 1.00, alpha: 1.0),
        operator: NSColor(red: 1.00, green: 0.48, blue: 0.52, alpha: 1.0),
        punctuation: NSColor(red: 0.70, green: 0.75, blue: 0.80, alpha: 1.0),
        diffAddedGutter: NSColor(red: 0.24, green: 0.68, blue: 0.36, alpha: 1.0),
        diffAddedBackground: NSColor(red: 0.15, green: 0.35, blue: 0.20, alpha: 0.3),
        diffAddedWordHighlight: NSColor(red: 0.18, green: 0.55, blue: 0.28, alpha: 0.5),
        diffDeletedGutter: NSColor(red: 0.90, green: 0.28, blue: 0.32, alpha: 1.0),
        diffDeletedBackground: NSColor(red: 0.42, green: 0.15, blue: 0.18, alpha: 0.3),
        diffDeletedWordHighlight: NSColor(red: 0.70, green: 0.18, blue: 0.22, alpha: 0.5),
        diffModifiedGutter: NSColor(red: 0.30, green: 0.60, blue: 0.95, alpha: 1.0)
    )

    public static let zedGray = Theme(
        id: "zed-gray",
        name: "Zed Slate Gray",
        isDark: true,
        background: NSColor(red: 0.158, green: 0.162, blue: 0.178, alpha: 1.0),
        gutterBackground: NSColor(red: 0.133, green: 0.137, blue: 0.150, alpha: 1.0),
        currentLineBackground: NSColor(red: 0.190, green: 0.195, blue: 0.215, alpha: 1.0),
        selectionBackground: NSColor(red: 0.280, green: 0.360, blue: 0.500, alpha: 0.65),
        excerptHeaderBackground: NSColor(red: 0.185, green: 0.192, blue: 0.216, alpha: 1.0),
        excerptHeaderBorder: NSColor(red: 0.245, green: 0.255, blue: 0.285, alpha: 1.0),
        foreground: NSColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1.0),
        gutterForeground: NSColor(red: 0.48, green: 0.52, blue: 0.58, alpha: 1.0),
        gutterActiveForeground: NSColor(red: 0.90, green: 0.92, blue: 0.98, alpha: 1.0),
        foldPlaceholderForeground: NSColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 1.0),
        keyword: NSColor(red: 0.92, green: 0.48, blue: 0.56, alpha: 1.0),
        type: NSColor(red: 0.90, green: 0.75, blue: 0.48, alpha: 1.0),
        function: NSColor(red: 0.42, green: 0.70, blue: 0.96, alpha: 1.0),
        string: NSColor(red: 0.60, green: 0.82, blue: 0.52, alpha: 1.0),
        number: NSColor(red: 0.88, green: 0.62, blue: 0.40, alpha: 1.0),
        comment: NSColor(red: 0.52, green: 0.57, blue: 0.64, alpha: 1.0),
        property: NSColor(red: 0.72, green: 0.82, blue: 0.95, alpha: 1.0),
        operator: NSColor(red: 0.52, green: 0.75, blue: 0.88, alpha: 1.0),
        punctuation: NSColor(red: 0.70, green: 0.74, blue: 0.82, alpha: 1.0),
        diffAddedGutter: NSColor(red: 0.28, green: 0.78, blue: 0.44, alpha: 1.0),
        diffAddedBackground: NSColor(red: 0.20, green: 0.45, blue: 0.25, alpha: 0.30),
        diffAddedWordHighlight: NSColor(red: 0.25, green: 0.65, blue: 0.35, alpha: 0.50),
        diffDeletedGutter: NSColor(red: 0.92, green: 0.32, blue: 0.38, alpha: 1.0),
        diffDeletedBackground: NSColor(red: 0.48, green: 0.18, blue: 0.22, alpha: 0.30),
        diffDeletedWordHighlight: NSColor(red: 0.78, green: 0.20, blue: 0.26, alpha: 0.50),
        diffModifiedGutter: NSColor(red: 0.38, green: 0.68, blue: 0.96, alpha: 1.0)
    )

    public static let macOSLight = Theme(
        id: "macos-light",
        name: "macOS Light",
        isDark: false,
        background: NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0),
        gutterBackground: NSColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1.0),
        currentLineBackground: NSColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1.0),
        selectionBackground: NSColor(red: 0.24, green: 0.48, blue: 0.88, alpha: 0.24),
        excerptHeaderBackground: NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0),
        excerptHeaderBorder: NSColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 1.0),
        foreground: NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0),
        gutterForeground: NSColor(red: 0.40, green: 0.44, blue: 0.52, alpha: 1.0),
        gutterActiveForeground: NSColor(red: 0.12, green: 0.24, blue: 0.48, alpha: 1.0),
        foldPlaceholderForeground: NSColor(red: 0.38, green: 0.43, blue: 0.52, alpha: 1.0),
        keyword: NSColor(red: 0.70, green: 0.14, blue: 0.28, alpha: 1.0),
        type: NSColor(red: 0.58, green: 0.34, blue: 0.04, alpha: 1.0),
        function: NSColor(red: 0.08, green: 0.30, blue: 0.68, alpha: 1.0),
        string: NSColor(red: 0.08, green: 0.42, blue: 0.20, alpha: 1.0),
        number: NSColor(red: 0.72, green: 0.31, blue: 0.08, alpha: 1.0),
        comment: NSColor(red: 0.40, green: 0.44, blue: 0.50, alpha: 1.0),
        property: NSColor(red: 0.10, green: 0.34, blue: 0.62, alpha: 1.0),
        operator: NSColor(red: 0.34, green: 0.36, blue: 0.44, alpha: 1.0),
        punctuation: NSColor(red: 0.30, green: 0.33, blue: 0.40, alpha: 1.0),
        diffAddedGutter: NSColor(red: 0.10, green: 0.55, blue: 0.24, alpha: 1.0),
        diffAddedBackground: NSColor(red: 0.72, green: 0.94, blue: 0.76, alpha: 0.62),
        diffAddedWordHighlight: NSColor(red: 0.36, green: 0.78, blue: 0.44, alpha: 0.52),
        diffDeletedGutter: NSColor(red: 0.78, green: 0.16, blue: 0.20, alpha: 1.0),
        diffDeletedBackground: NSColor(red: 0.98, green: 0.78, blue: 0.80, alpha: 0.62),
        diffDeletedWordHighlight: NSColor(red: 0.92, green: 0.38, blue: 0.42, alpha: 0.50),
        diffModifiedGutter: NSColor(red: 0.12, green: 0.42, blue: 0.82, alpha: 1.0)
    )

    public static let unifiedDark = Theme(
        id: "unified-dark",
        name: "macOS Window Unified",
        isDark: true,
        background: NSColor(red: 43.0 / 255.0, green: 41.0 / 255.0, blue: 40.0 / 255.0, alpha: 1.0),
        gutterBackground: NSColor(red: 43.0 / 255.0, green: 41.0 / 255.0, blue: 40.0 / 255.0, alpha: 1.0),
        currentLineBackground: NSColor(red: 0.182, green: 0.184, blue: 0.194, alpha: 1.0),
        selectionBackground: NSColor(red: 0.260, green: 0.350, blue: 0.500, alpha: 0.65),
        excerptHeaderBackground: NSColor(red: 43.0 / 255.0, green: 41.0 / 255.0, blue: 40.0 / 255.0, alpha: 1.0),
        excerptHeaderBorder: NSColor(red: 0.200, green: 0.205, blue: 0.215, alpha: 1.0),
        foreground: NSColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1.0),
        gutterForeground: NSColor(red: 0.46, green: 0.48, blue: 0.54, alpha: 1.0),
        gutterActiveForeground: NSColor(red: 0.92, green: 0.94, blue: 0.98, alpha: 1.0),
        foldPlaceholderForeground: NSColor(red: 0.55, green: 0.58, blue: 0.66, alpha: 1.0),
        keyword: NSColor(red: 0.94, green: 0.48, blue: 0.58, alpha: 1.0),
        type: NSColor(red: 0.92, green: 0.78, blue: 0.48, alpha: 1.0),
        function: NSColor(red: 0.42, green: 0.72, blue: 0.98, alpha: 1.0),
        string: NSColor(red: 0.60, green: 0.84, blue: 0.52, alpha: 1.0),
        number: NSColor(red: 0.90, green: 0.64, blue: 0.40, alpha: 1.0),
        comment: NSColor(red: 0.50, green: 0.54, blue: 0.60, alpha: 1.0),
        property: NSColor(red: 0.74, green: 0.84, blue: 0.96, alpha: 1.0),
        operator: NSColor(red: 0.54, green: 0.76, blue: 0.88, alpha: 1.0),
        punctuation: NSColor(red: 0.72, green: 0.76, blue: 0.84, alpha: 1.0),
        diffAddedGutter: NSColor(red: 0.28, green: 0.78, blue: 0.44, alpha: 1.0),
        diffAddedBackground: NSColor(red: 0.20, green: 0.45, blue: 0.25, alpha: 0.28),
        diffAddedWordHighlight: NSColor(red: 0.25, green: 0.65, blue: 0.35, alpha: 0.48),
        diffDeletedGutter: NSColor(red: 0.92, green: 0.32, blue: 0.38, alpha: 1.0),
        diffDeletedBackground: NSColor(red: 0.48, green: 0.18, blue: 0.22, alpha: 0.28),
        diffDeletedWordHighlight: NSColor(red: 0.78, green: 0.20, blue: 0.26, alpha: 0.48),
        diffModifiedGutter: NSColor(red: 0.38, green: 0.68, blue: 0.96, alpha: 1.0)
    )

    public static let allThemes: [Theme] = [
        .macOSLight,
        .unifiedDark,
        .zedGray,
        .zedDark,
        .tokyoNight,
        .githubDark
    ]
}
