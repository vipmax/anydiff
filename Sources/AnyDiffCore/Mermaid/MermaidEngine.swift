import Foundation
import CoreGraphics

public enum MermaidEngine {
    public static func isMermaidLanguage(_ language: String?) -> Bool {
        guard let language else { return false }
        return language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid"
    }

    public static func parse(_ source: String) throws -> MermaidParsedDiagram {
        try MermaidParser.parse(source)
    }

    public static func layout(
        _ parsed: MermaidParsedDiagram,
        measurer: MermaidTextMeasurer = FallbackMermaidTextMeasurer(),
        maxWidth: CGFloat = 760
    ) -> MermaidLayoutDiagram {
        switch parsed {
        case .graph(let ast):
            return .graph(MermaidSugiyamaLayout.layout(ast, measurer: measurer, maxWidth: maxWidth))
        case .sequence(let ast):
            return .sequence(MermaidSequenceLayout.layout(ast, measurer: measurer))
        case .pie(let ast):
            return .pie(MermaidSequenceLayout.layoutPie(ast, measurer: measurer))
        }
    }

    public static func parseAndLayout(
        _ source: String,
        measurer: MermaidTextMeasurer = FallbackMermaidTextMeasurer(),
        maxWidth: CGFloat = 760
    ) throws -> MermaidLayoutDiagram {
        let parsed = try parse(source)
        return layout(parsed, measurer: measurer, maxWidth: maxWidth)
    }
}
