import XCTest
@testable import AnyDiffCore
@testable import AnyDiffUI

final class MermaidTests: XCTestCase {
    func testFlowchartFromScreenshotParsesLayoutsAndRenders() throws {
        let source = """
        flowchart TD
            A["Пользователь отправляет задачу"] --> B["Агент работает и вызывает инструменты"]
            B --> C{"Ход завершён?"}
            C -- "Нет" --> B
            C -- "Да" --> D["Бэкенд собирает ограниченную сводку по ходу"]
            D --> E["Выбирает категории вопросов по фактам: изменения, команды, тип задачи"]
            E --> F["Отправляет один запрос Jev"]
            F --> G{"Jev ответил?"}
            G -- "Да" --> H["Код Anycode применяет правила к оценкам и фактам"]
            H --> I["Показывает карточку в чате и статус у агента"]
            G -- "Нет" --> J["Показывает «Не удалось проверить»; работа агента не меняется"]
        """

        let parsed = try MermaidEngine.parse(source)
        guard case .graph(let ast) = parsed else {
            XCTFail("Expected graph AST")
            return
        }

        XCTAssertEqual(ast.type, .flowchart)
        XCTAssertEqual(ast.direction, .topDown)
        XCTAssertEqual(ast.nodes.count, 10)
        XCTAssertEqual(ast.edges.count, 10)

        let cNode = ast.nodes.first(where: { $0.id == "C" })
        XCTAssertEqual(cNode?.shape, .diamond)
        XCTAssertEqual(cNode?.label, "Ход завершён?")

        let loopEdge = ast.edges.first(where: { $0.source == "C" && $0.target == "B" })
        XCTAssertEqual(loopEdge?.label, "Нет")

        let measurer = MermaidCoreTextMeasurer()
        let layout = MermaidEngine.layout(parsed, measurer: measurer, maxWidth: 760)
        guard case .graph(let positioned) = layout else {
            XCTFail("Expected positioned graph")
            return
        }

        XCTAssertGreaterThan(positioned.size.width, 200)
        XCTAssertGreaterThan(positioned.size.height, 400)
        XCTAssertEqual(positioned.nodes.count, 10)
        XCTAssertTrue(positioned.edges.contains(where: { $0.isBackEdge && $0.labelLines == ["Нет"] }))

        // Ensure nodes don't overlap each other
        for i in 0..<positioned.nodes.count {
            for j in (i + 1)..<positioned.nodes.count {
                XCTAssertFalse(
                    positioned.nodes[i].frame.intersects(positioned.nodes[j].frame),
                    "Nodes \(positioned.nodes[i].id) and \(positioned.nodes[j].id) overlap"
                )
            }
        }

        // Render in both dark and light themes
        for theme in [Theme.zedDark, Theme.githubLight] {
            let palette = MermaidThemePalette(theme: theme)
            XCTAssertGreaterThanOrEqual(palette.nodeAccents.count, 6)
            let image = MermaidCGContextRenderer.renderImage(
                layout,
                palette: palette,
                scale: 2.0,
                opaqueBackground: theme.background
            )
            XCTAssertNotNil(image)
            XCTAssertGreaterThan(image?.size.width ?? 0, 100)
            XCTAssertGreaterThan(image?.size.height ?? 0, 100)
            let png = image.flatMap(MermaidCGContextRenderer.pngData(from:))
            XCTAssertGreaterThan(png?.count ?? 0, 1000)
        }
    }

    func testFlowchartSubgraphsShapesAndChains() throws {
        let source = """
        flowchart LR
            subgraph Backend["API & Storage"]
                API([Gateway]) -.->|auth| Auth[[Validator]] ==> DB[(Postgres)]
            end
            Client((User)) --> API
            DB -- "ok" --> Done(((Complete)))
        """

        let layout = try MermaidEngine.parseAndLayout(source, measurer: MermaidCoreTextMeasurer())
        guard case .graph(let graph) = layout else {
            XCTFail("Expected graph layout")
            return
        }

        XCTAssertEqual(graph.groups.count, 1)
        XCTAssertEqual(graph.groups.first?.title, "API & Storage")
        XCTAssertEqual(graph.nodes.first(where: { $0.id == "DB" })?.shape, .cylinder)
        XCTAssertEqual(graph.nodes.first(where: { $0.id == "Done" })?.shape, .doubleCircle)
        XCTAssertEqual(graph.edges.count, 4)
    }

    func testSequenceDiagramLayoutAndRender() throws {
        let source = """
        sequenceDiagram
            autonumber
            actor U as User
            participant App as AnyDiff
            participant LLM as Agent
            U->>+App: Send prompt
            alt Valid input
                App->>+LLM: Stream request
                LLM-->>-App: Response chunks
            else Empty
                App-->>U: Show warning
            end
            Note over App,LLM: Pure Swift renderer
            App-->>-U: Render diagram
        """

        let layout = try MermaidEngine.parseAndLayout(source, measurer: MermaidCoreTextMeasurer())
        guard case .sequence(let seq) = layout else {
            XCTFail("Expected sequence layout")
            return
        }

        XCTAssertEqual(seq.participants.count, 3)
        XCTAssertEqual(seq.participants.first?.kind, .actor)
        XCTAssertEqual(seq.blocks.count, 1)
        XCTAssertEqual(seq.blocks.first?.dividers.count, 1)
        XCTAssertEqual(seq.notes.count, 1)
        XCTAssertEqual(seq.messages.count, 5)
        XCTAssertFalse(seq.activations.isEmpty)

        let image = MermaidCGContextRenderer.renderImage(
            layout,
            palette: MermaidThemePalette(theme: .zedDark),
            opaqueBackground: Theme.zedDark.background
        )
        XCTAssertNotNil(image)
    }

    func testStateClassERAndPieDiagrams() throws {
        let stateSrc = """
        stateDiagram-v2
            [*] --> Idle
            Idle --> Running : start
            state Running {
                Streaming --> Rendering
            }
            Running --> [*]
        """
        let stateLayout = try MermaidEngine.parseAndLayout(stateSrc)
        XCTAssertNotNil(MermaidCGContextRenderer.renderImage(stateLayout, palette: MermaidThemePalette(theme: .zedDark)))

        let classSrc = """
        classDiagram
            class Renderer {
                +Theme theme
                +render(source) Image
            }
            MermaidRenderer <|-- CoreGraphicsRenderer : implements
        """
        let classLayout = try MermaidEngine.parseAndLayout(classSrc)
        XCTAssertNotNil(MermaidCGContextRenderer.renderImage(classLayout, palette: MermaidThemePalette(theme: .zedDark)))

        let erSrc = """
        erDiagram
            USER ||--o{ ORDER : places
            USER {
                int id PK
                string email UK
            }
            ORDER {
                int id PK
                int user_id FK
            }
        """
        let erLayout = try MermaidEngine.parseAndLayout(erSrc)
        XCTAssertNotNil(MermaidCGContextRenderer.renderImage(erLayout, palette: MermaidThemePalette(theme: .zedDark)))

        let pieSrc = """
        pie showData
            title Diagram Usage
            "Flowchart" : 55
            "Sequence" : 25
            "Other" : 20
        """
        let pieLayout = try MermaidEngine.parseAndLayout(pieSrc)
        XCTAssertNotNil(MermaidCGContextRenderer.renderImage(pieLayout, palette: MermaidThemePalette(theme: .zedDark)))
    }

    func testUnclosedTrailingCodeBlockDetectionForStreaming() {
        let unclosed = """
        Here is a diagram:
        ```mermaid
        flowchart TD
            A --> B
        """
        XCTAssertTrue(MarkdownParser.hasUnclosedTrailingCodeBlock(unclosed))

        let closed = unclosed + "\n```"
        XCTAssertFalse(MarkdownParser.hasUnclosedTrailingCodeBlock(closed))
    }

    @MainActor
    func testMermaidBlockViewMeasuresAndCompilesInChatCell() {
        let markdown = """
        Explanation before:

        ```mermaid
        flowchart TD
            A[Start] --> B[Finish]
        ```
        """
        let msg = AgentMessage(
            role: .assistant,
            content: markdown,
            isStreaming: false
        )
        let cell = AgentMessageCell(
            message: msg,
            theme: .zedDark,
            nativeTextSelectionEnabled: true
        )
        let height = cell.measureHeight(for: 640)
        XCTAssertGreaterThan(height, 100)

        let hasMermaidView = cell.subviews.contains(where: { $0 is MermaidBlockView })
        XCTAssertTrue(hasMermaidView)
    }

    @MainActor
    func testVectorViewDrawsInFlippedAppKitContext() {
        let source = """
        flowchart TD
            A["Start"] --> B{"Decision?"}
            B -- "Yes" --> C["Done"]
        """
        let palette = MermaidThemePalette(theme: .zedDark)
        let result = MermaidRenderCache.layoutSync(code: source, palette: palette)
        guard case .diagram(let diagram, _) = result else {
            XCTFail("Expected diagram layout result")
            return
        }

        let vectorView = MermaidVectorView(frame: NSRect(origin: .zero, size: diagram.size))
        vectorView.diagram = diagram
        vectorView.palette = palette

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(diagram.size.width * 2)),
            pixelsHigh: Int(ceil(diagram.size.height * 2)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        XCTAssertNotNil(rep)
        guard let rep, let gfx = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx
        let ctx = gfx.cgContext
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: diagram.size.height)
        ctx.scaleBy(x: 1, y: -1)
        vectorView.draw(vectorView.bounds)
        NSGraphicsContext.restoreGraphicsState()

        let png = rep.representation(using: .png, properties: [:])
        XCTAssertGreaterThan(png?.count ?? 0, 500)
    }
}
