import Foundation
import CoreGraphics

// MARK: - Diagram Kind & Direction

public enum MermaidDiagramType: String, Sendable, CaseIterable {
    case flowchart
    case sequence
    case state
    case classDiagram
    case erDiagram
    case pie
}

public enum MermaidDirection: String, Sendable {
    case topDown = "TD"
    case bottomTop = "BT"
    case leftRight = "LR"
    case rightLeft = "RL"

    public var isHorizontal: Bool {
        self == .leftRight || self == .rightLeft
    }

    public var isReversed: Bool {
        self == .bottomTop || self == .rightLeft
    }
}

// MARK: - Graph / Flowchart AST

public enum MermaidNodeShape: String, Sendable {
    case rectangle
    case rounded
    case stadium
    case subroutine
    case cylinder
    case circle
    case doubleCircle
    case diamond
    case hexagon
    case parallelogram
    case parallelogramAlt
    case trapezoid
    case trapezoidAlt
    case stateStart
    case stateEnd
    case classBox
    case entityBox
}

public enum MermaidEdgeLineStyle: String, Sendable {
    case solid
    case dotted
    case thick
}

public enum MermaidArrowHead: String, Sendable {
    case none
    case normal
    case open
    case circle
    case cross
    // UML class markers
    case inheritance
    case composition
    case aggregation
    // ER cardinality markers
    case erOnlyOne
    case erZeroOrOne
    case erOneOrMore
    case erZeroOrMore
}

public struct MermaidNode: Sendable, Equatable {
    public let id: String
    public var label: String
    public var shape: MermaidNodeShape
    public var subtitleLines: [String]
    public var secondaryLines: [String]
    public var subgraphID: String?

    public init(
        id: String,
        label: String,
        shape: MermaidNodeShape = .rectangle,
        subtitleLines: [String] = [],
        secondaryLines: [String] = [],
        subgraphID: String? = nil
    ) {
        self.id = id
        self.label = label
        self.shape = shape
        self.subtitleLines = subtitleLines
        self.secondaryLines = secondaryLines
        self.subgraphID = subgraphID
    }
}

public struct MermaidEdge: Sendable, Equatable {
    public let source: String
    public let target: String
    public var label: String?
    public var lineStyle: MermaidEdgeLineStyle
    public var sourceArrow: MermaidArrowHead
    public var targetArrow: MermaidArrowHead
    public var sourceLabel: String?
    public var targetLabel: String?

    public init(
        source: String,
        target: String,
        label: String? = nil,
        lineStyle: MermaidEdgeLineStyle = .solid,
        sourceArrow: MermaidArrowHead = .none,
        targetArrow: MermaidArrowHead = .normal,
        sourceLabel: String? = nil,
        targetLabel: String? = nil
    ) {
        self.source = source
        self.target = target
        self.label = label
        self.lineStyle = lineStyle
        self.sourceArrow = sourceArrow
        self.targetArrow = targetArrow
        self.sourceLabel = sourceLabel
        self.targetLabel = targetLabel
    }
}

public struct MermaidSubgraph: Sendable, Equatable {
    public let id: String
    public var title: String
    public var parentID: String?
    public var nodeIDs: [String]
    public var direction: MermaidDirection?

    public init(
        id: String,
        title: String,
        parentID: String? = nil,
        nodeIDs: [String] = [],
        direction: MermaidDirection? = nil
    ) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.nodeIDs = nodeIDs
        self.direction = direction
    }
}

public struct MermaidGraphAST: Sendable, Equatable {
    public let type: MermaidDiagramType
    public var direction: MermaidDirection
    public var nodes: [MermaidNode]
    public var edges: [MermaidEdge]
    public var subgraphs: [MermaidSubgraph]

    public init(
        type: MermaidDiagramType,
        direction: MermaidDirection = .topDown,
        nodes: [MermaidNode] = [],
        edges: [MermaidEdge] = [],
        subgraphs: [MermaidSubgraph] = []
    ) {
        self.type = type
        self.direction = direction
        self.nodes = nodes
        self.edges = edges
        self.subgraphs = subgraphs
    }
}

// MARK: - Sequence Diagram AST

public enum MermaidParticipantKind: String, Sendable {
    case participant
    case actor
}

public struct MermaidSequenceParticipant: Sendable, Equatable {
    public let id: String
    public var label: String
    public var kind: MermaidParticipantKind

    public init(id: String, label: String, kind: MermaidParticipantKind = .participant) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public enum MermaidSequenceNotePosition: String, Sendable {
    case leftOf
    case rightOf
    case over
}

public struct MermaidSequenceMessage: Sendable, Equatable {
    public let from: String
    public let to: String
    public let text: String
    public let lineStyle: MermaidEdgeLineStyle
    public let arrowHead: MermaidArrowHead
    public let activateTarget: Bool
    public let deactivateTarget: Bool

    public init(
        from: String,
        to: String,
        text: String,
        lineStyle: MermaidEdgeLineStyle = .solid,
        arrowHead: MermaidArrowHead = .normal,
        activateTarget: Bool = false,
        deactivateTarget: Bool = false
    ) {
        self.from = from
        self.to = to
        self.text = text
        self.lineStyle = lineStyle
        self.arrowHead = arrowHead
        self.activateTarget = activateTarget
        self.deactivateTarget = deactivateTarget
    }
}

public struct MermaidSequenceNote: Sendable, Equatable {
    public let position: MermaidSequenceNotePosition
    public let participants: [String]
    public let text: String

    public init(position: MermaidSequenceNotePosition, participants: [String], text: String) {
        self.position = position
        self.participants = participants
        self.text = text
    }
}

public enum MermaidSequenceBlockKind: String, Sendable {
    case loop
    case alt
    case opt
    case par
    case critical
    case `break`
    case rect
}

public enum MermaidSequenceItem: Sendable, Equatable {
    case message(MermaidSequenceMessage)
    case note(MermaidSequenceNote)
    case activate(String)
    case deactivate(String)
    case blockStart(kind: MermaidSequenceBlockKind, label: String)
    case blockDivider(label: String)
    case blockEnd
}

public struct MermaidSequenceAST: Sendable, Equatable {
    public var participants: [MermaidSequenceParticipant]
    public var items: [MermaidSequenceItem]
    public var autonumber: Bool

    public init(
        participants: [MermaidSequenceParticipant] = [],
        items: [MermaidSequenceItem] = [],
        autonumber: Bool = false
    ) {
        self.participants = participants
        self.items = items
        self.autonumber = autonumber
    }
}

// MARK: - Pie Chart AST

public struct MermaidPieSlice: Sendable, Equatable {
    public let label: String
    public let value: Double

    public init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

public struct MermaidPieAST: Sendable, Equatable {
    public var title: String?
    public var showData: Bool
    public var slices: [MermaidPieSlice]

    public init(title: String? = nil, showData: Bool = false, slices: [MermaidPieSlice] = []) {
        self.title = title
        self.showData = showData
        self.slices = slices
    }
}

// MARK: - Parsed Diagram Wrapper

public enum MermaidParsedDiagram: Sendable, Equatable {
    case graph(MermaidGraphAST)
    case sequence(MermaidSequenceAST)
    case pie(MermaidPieAST)

    public var diagramType: MermaidDiagramType {
        switch self {
        case .graph(let ast): return ast.type
        case .sequence: return .sequence
        case .pie: return .pie
        }
    }
}

// MARK: - Text Measurement Protocol

public enum MermaidTextRole: Sendable {
    case nodeLabel
    case nodeHeader
    case nodeDetail
    case edgeLabel
    case groupTitle
    case sequenceParticipant
    case sequenceMessage
    case sequenceNote
    case pieTitle
    case pieLegend
}

public protocol MermaidTextMeasurer: Sendable {
    func measureText(_ text: String, role: MermaidTextRole, maxWidth: CGFloat) -> CGSize
    func wrapText(_ text: String, role: MermaidTextRole, maxWidth: CGFloat) -> (lines: [String], size: CGSize)
}

public struct FallbackMermaidTextMeasurer: MermaidTextMeasurer {
    public init() {}

    public func measureText(_ text: String, role: MermaidTextRole, maxWidth: CGFloat) -> CGSize {
        wrapText(text, role: role, maxWidth: maxWidth).size
    }

    public func wrapText(_ text: String, role: MermaidTextRole, maxWidth: CGFloat) -> (lines: [String], size: CGSize) {
        let charWidth: CGFloat
        let lineHeight: CGFloat
        switch role {
        case .edgeLabel, .nodeDetail, .sequenceMessage, .sequenceNote, .pieLegend:
            charWidth = 6.8
            lineHeight = 15
        case .pieTitle:
            charWidth = 8.4
            lineHeight = 20
        default:
            charWidth = 7.5
            lineHeight = 17
        }

        let rawLines = text.components(separatedBy: "\n")
        var wrapped: [String] = []
        let maxChars = max(8, Int(floor(maxWidth / charWidth)))

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                wrapped.append("")
                continue
            }
            if trimmed.count <= maxChars {
                wrapped.append(trimmed)
                continue
            }
            var current = ""
            for word in trimmed.split(separator: " ") {
                if current.isEmpty {
                    current = String(word)
                } else if current.count + 1 + word.count <= maxChars {
                    current += " " + word
                } else {
                    wrapped.append(current)
                    current = String(word)
                }
            }
            if !current.isEmpty {
                wrapped.append(current)
            }
        }

        let widest = wrapped.map { CGFloat($0.count) * charWidth }.max() ?? 0
        let totalHeight = max(lineHeight, CGFloat(wrapped.count) * lineHeight)
        return (wrapped, CGSize(width: ceil(widest), height: ceil(totalHeight)))
    }
}

// MARK: - Positioned / Laid-out Output Models

public struct MermaidPositionedNode: Sendable {
    public let id: String
    public let wrappedLines: [String]
    public let subtitleLines: [String]
    public let secondaryLines: [String]
    public let shape: MermaidNodeShape
    public let frame: CGRect

    public init(
        id: String,
        wrappedLines: [String],
        subtitleLines: [String] = [],
        secondaryLines: [String] = [],
        shape: MermaidNodeShape,
        frame: CGRect
    ) {
        self.id = id
        self.wrappedLines = wrappedLines
        self.subtitleLines = subtitleLines
        self.secondaryLines = secondaryLines
        self.shape = shape
        self.frame = frame
    }
}

public struct MermaidPositionedEdge: Sendable {
    public let source: String
    public let target: String
    public let points: [CGPoint]
    public let isBackEdge: Bool
    public let lineStyle: MermaidEdgeLineStyle
    public let sourceArrow: MermaidArrowHead
    public let targetArrow: MermaidArrowHead
    public let labelLines: [String]
    public let labelFrame: CGRect?
    public let sourceLabel: String?
    public let targetLabel: String?

    public init(
        source: String,
        target: String,
        points: [CGPoint],
        isBackEdge: Bool = false,
        lineStyle: MermaidEdgeLineStyle,
        sourceArrow: MermaidArrowHead,
        targetArrow: MermaidArrowHead,
        labelLines: [String] = [],
        labelFrame: CGRect? = nil,
        sourceLabel: String? = nil,
        targetLabel: String? = nil
    ) {
        self.source = source
        self.target = target
        self.points = points
        self.isBackEdge = isBackEdge
        self.lineStyle = lineStyle
        self.sourceArrow = sourceArrow
        self.targetArrow = targetArrow
        self.labelLines = labelLines
        self.labelFrame = labelFrame
        self.sourceLabel = sourceLabel
        self.targetLabel = targetLabel
    }
}

public struct MermaidPositionedGroup: Sendable {
    public let id: String
    public let title: String
    public let frame: CGRect
    public let headerHeight: CGFloat
    public let depth: Int

    public init(id: String, title: String, frame: CGRect, headerHeight: CGFloat, depth: Int) {
        self.id = id
        self.title = title
        self.frame = frame
        self.headerHeight = headerHeight
        self.depth = depth
    }
}

public struct MermaidPositionedGraph: Sendable {
    public let type: MermaidDiagramType
    public let size: CGSize
    public let groups: [MermaidPositionedGroup]
    public let nodes: [MermaidPositionedNode]
    public let edges: [MermaidPositionedEdge]

    public init(
        type: MermaidDiagramType,
        size: CGSize,
        groups: [MermaidPositionedGroup],
        nodes: [MermaidPositionedNode],
        edges: [MermaidPositionedEdge]
    ) {
        self.type = type
        self.size = size
        self.groups = groups
        self.nodes = nodes
        self.edges = edges
    }
}

public struct MermaidPositionedSequenceParticipant: Sendable {
    public let id: String
    public let labelLines: [String]
    public let kind: MermaidParticipantKind
    public let centerX: CGFloat
    public let topFrame: CGRect
    public let bottomFrame: CGRect
    public let lifelineTopY: CGFloat
    public let lifelineBottomY: CGFloat
}

public struct MermaidPositionedSequenceMessage: Sendable {
    public let fromX: CGFloat
    public let toX: CGFloat
    public let y: CGFloat
    public let isSelfMessage: Bool
    public let labelLines: [String]
    public let labelFrame: CGRect
    public let lineStyle: MermaidEdgeLineStyle
    public let arrowHead: MermaidArrowHead
}

public struct MermaidPositionedSequenceNote: Sendable {
    public let frame: CGRect
    public let labelLines: [String]
}

public struct MermaidPositionedSequenceBlock: Sendable {
    public let kind: MermaidSequenceBlockKind
    public let label: String
    public let frame: CGRect
    public let dividers: [(y: CGFloat, label: String)]
}

public struct MermaidPositionedSequenceActivation: Sendable {
    public let frame: CGRect
}

public struct MermaidPositionedSequence: Sendable {
    public let size: CGSize
    public let participants: [MermaidPositionedSequenceParticipant]
    public let activations: [MermaidPositionedSequenceActivation]
    public let blocks: [MermaidPositionedSequenceBlock]
    public let messages: [MermaidPositionedSequenceMessage]
    public let notes: [MermaidPositionedSequenceNote]
}

public struct MermaidPositionedPieSlice: Sendable {
    public let label: String
    public let value: Double
    public let percentage: Double
    public let startAngle: CGFloat
    public let endAngle: CGFloat
    public let colorIndex: Int
}

public struct MermaidPositionedPie: Sendable {
    public let size: CGSize
    public let title: String?
    public let titleCenter: CGPoint?
    public let center: CGPoint
    public let radius: CGFloat
    public let slices: [MermaidPositionedPieSlice]
    public let showData: Bool
    public let legendOrigin: CGPoint
}

public enum MermaidLayoutDiagram: Sendable {
    case graph(MermaidPositionedGraph)
    case sequence(MermaidPositionedSequence)
    case pie(MermaidPositionedPie)

    public var size: CGSize {
        switch self {
        case .graph(let g): return g.size
        case .sequence(let s): return s.size
        case .pie(let p): return p.size
        }
    }
}

public enum MermaidError: Error, LocalizedError, Equatable {
    case emptyInput
    case unsupportedDiagramType(String)
    case noRenderableContent

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Empty Mermaid diagram"
        case .unsupportedDiagramType(let header):
            return "Unsupported Mermaid diagram type: \(header)"
        case .noRenderableContent:
            return "No nodes or elements found in Mermaid diagram"
        }
    }
}
