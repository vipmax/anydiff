import Foundation
import CoreGraphics

enum MermaidSequenceLayout {
    static func layout(
        _ ast: MermaidSequenceAST,
        measurer: MermaidTextMeasurer
    ) -> MermaidPositionedSequence {
        let participantCount = ast.participants.count
        let idToIndex = Dictionary(ast.participants.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Measure participant headers
        var participantInfos: [(lines: [String], size: CGSize)] = []
        for p in ast.participants {
            let wrapped = measurer.wrapText(p.label, role: .sequenceParticipant, maxWidth: 150)
            let boxW = max(96, wrapped.size.width + 26)
            let boxH = p.kind == .actor ? max(54, wrapped.size.height + 36) : max(38, wrapped.size.height + 18)
            participantInfos.append((wrapped.lines, CGSize(width: ceil(boxW), height: ceil(boxH))))
        }

        let topHeaderHeight = participantInfos.map(\.size.height).max() ?? 42
        let baseGap: CGFloat = 34
        var columnGaps = Array(repeating: baseGap, count: max(0, participantCount - 1))

        // Expand adjacent column gaps to fit message labels comfortably
        var extraLeftMargin: CGFloat = 24
        var extraRightMargin: CGFloat = 24

        for item in ast.items {
            switch item {
            case .message(let msg):
                guard let fromIdx = idToIndex[msg.from], let toIdx = idToIndex[msg.to] else { continue }
                let msgSize = measurer.wrapText(msg.text, role: .sequenceMessage, maxWidth: 220).size
                if fromIdx == toIdx {
                    if fromIdx < columnGaps.count {
                        columnGaps[fromIdx] = max(columnGaps[fromIdx], msgSize.width + 58)
                    } else {
                        extraRightMargin = max(extraRightMargin, msgSize.width + 64)
                    }
                } else {
                    let lo = min(fromIdx, toIdx)
                    let hi = max(fromIdx, toIdx)
                    let spanCount = hi - lo
                    let needed = msgSize.width + 36
                    let existingWidth = (lo..<hi).reduce(CGFloat(0)) { acc, idx in
                        acc + participantInfos[idx].size.width / 2 + columnGaps[idx] + participantInfos[idx + 1].size.width / 2
                    }
                    if needed > existingWidth {
                        let deficit = (needed - existingWidth) / CGFloat(spanCount)
                        for idx in lo..<hi {
                            columnGaps[idx] += deficit
                        }
                    }
                }

            case .note(let note):
                let noteSize = measurer.wrapText(note.text, role: .sequenceNote, maxWidth: 160).size
                let boxW = max(70, noteSize.width + 20)
                if let firstID = note.participants.first, let idx = idToIndex[firstID] {
                    if note.position == .leftOf {
                        if idx == 0 {
                            extraLeftMargin = max(extraLeftMargin, boxW + 24)
                        } else {
                            columnGaps[idx - 1] = max(columnGaps[idx - 1], boxW + 18)
                        }
                    } else if note.position == .rightOf {
                        if idx == participantCount - 1 {
                            extraRightMargin = max(extraRightMargin, boxW + 24)
                        } else {
                            columnGaps[idx] = max(columnGaps[idx], boxW + 18)
                        }
                    }
                }

            default:
                break
            }
        }

        // Compute participant X centers
        var centerX = Array(repeating: CGFloat(0), count: participantCount)
        var cursorX = extraLeftMargin
        for i in 0..<participantCount {
            let w = participantInfos[i].size.width
            centerX[i] = cursorX + w / 2
            cursorX += w
            if i < columnGaps.count {
                cursorX += columnGaps[i]
            }
        }
        let totalWidth = ceil(cursorX + extraRightMargin)

        // 2. Vertical timeline layout
        let topMargin: CGFloat = 20
        let lifelineStartY = topMargin + topHeaderHeight
        var cursorY = lifelineStartY + 26

        var messages: [MermaidPositionedSequenceMessage] = []
        var notes: [MermaidPositionedSequenceNote] = []
        var completedBlocks: [MermaidPositionedSequenceBlock] = []
        var completedActivations: [MermaidPositionedSequenceActivation] = []

        struct OpenBlock {
            let kind: MermaidSequenceBlockKind
            let label: String
            let startY: CGFloat
            let depth: Int
            var dividers: [(y: CGFloat, label: String)]
        }
        var blockStack: [OpenBlock] = []
        var activationStacks: [Int: [CGFloat]] = [:]

        func pushActivation(_ idx: Int, at y: CGFloat) {
            activationStacks[idx, default: []].append(y)
        }
        func popActivation(_ idx: Int, at y: CGFloat) {
            guard var stack = activationStacks[idx], let startY = stack.popLast() else { return }
            activationStacks[idx] = stack
            let depthOffset = CGFloat(stack.count) * 4
            let rect = CGRect(x: centerX[idx] - 5 + depthOffset, y: startY, width: 10, height: max(18, y - startY))
            completedActivations.append(MermaidPositionedSequenceActivation(frame: rect))
        }

        for item in ast.items {
            switch item {
            case .activate(let id):
                if let idx = idToIndex[id] {
                    pushActivation(idx, at: cursorY - 6)
                }

            case .deactivate(let id):
                if let idx = idToIndex[id] {
                    popActivation(idx, at: cursorY)
                }

            case .blockStart(let kind, let label):
                blockStack.append(OpenBlock(
                    kind: kind,
                    label: label,
                    startY: cursorY,
                    depth: blockStack.count,
                    dividers: []
                ))
                cursorY += 32

            case .blockDivider(let label):
                if !blockStack.isEmpty {
                    cursorY += 10
                    blockStack[blockStack.count - 1].dividers.append((y: cursorY, label: label))
                    cursorY += 26
                }

            case .blockEnd:
                if let closed = blockStack.popLast() {
                    let endY = cursorY + 6
                    let inset = CGFloat(closed.depth) * 10
                    let minX = (centerX.first ?? 40) - 56 + inset
                    let maxX = (centerX.last ?? 160) + 56 - inset
                    completedBlocks.append(MermaidPositionedSequenceBlock(
                        kind: closed.kind,
                        label: closed.label,
                        frame: CGRect(x: max(12, minX), y: closed.startY, width: max(100, maxX - max(12, minX)), height: endY - closed.startY),
                        dividers: closed.dividers
                    ))
                    cursorY = endY + 14
                }

            case .note(let note):
                let wrapped = measurer.wrapText(note.text, role: .sequenceNote, maxWidth: 160)
                let boxW = max(70, wrapped.size.width + 20)
                let boxH = max(28, wrapped.size.height + 14)

                let indices = note.participants.compactMap { idToIndex[$0] }
                let firstIdx = indices.min() ?? 0
                let lastIdx = indices.max() ?? firstIdx

                let noteX: CGFloat
                switch note.position {
                case .leftOf:
                    noteX = centerX[firstIdx] - 12 - boxW
                case .rightOf:
                    noteX = centerX[firstIdx] + 12
                case .over:
                    if firstIdx == lastIdx {
                        noteX = centerX[firstIdx] - boxW / 2
                    } else {
                        let spanMid = (centerX[firstIdx] + centerX[lastIdx]) / 2
                        let minW = abs(centerX[lastIdx] - centerX[firstIdx]) + 36
                        let w = max(boxW, minW)
                        notes.append(MermaidPositionedSequenceNote(
                            frame: CGRect(x: spanMid - w / 2, y: cursorY, width: w, height: boxH),
                            labelLines: wrapped.lines
                        ))
                        cursorY += boxH + 16
                        continue
                    }
                }
                notes.append(MermaidPositionedSequenceNote(
                    frame: CGRect(x: max(10, noteX), y: cursorY, width: boxW, height: boxH),
                    labelLines: wrapped.lines
                ))
                cursorY += boxH + 16

            case .message(let msg):
                guard let fromIdx = idToIndex[msg.from], let toIdx = idToIndex[msg.to] else { continue }
                let wrapped = measurer.wrapText(msg.text, role: .sequenceMessage, maxWidth: 220)
                let labelH = msg.text.isEmpty ? 0 : wrapped.size.height
                let labelW = msg.text.isEmpty ? 0 : wrapped.size.width

                let isSelf = fromIdx == toIdx
                cursorY += max(18, labelH + 8)

                let fx = centerX[fromIdx]
                let tx = centerX[toIdx]
                let labelFrame: CGRect
                if isSelf {
                    labelFrame = CGRect(x: fx + 36, y: cursorY - labelH / 2 + 12, width: labelW, height: labelH)
                } else {
                    let midX = (fx + tx) / 2
                    labelFrame = CGRect(x: midX - labelW / 2, y: cursorY - labelH - 5, width: labelW, height: labelH)
                }

                messages.append(MermaidPositionedSequenceMessage(
                    fromX: fx,
                    toX: tx,
                    y: cursorY,
                    isSelfMessage: isSelf,
                    labelLines: wrapped.lines,
                    labelFrame: labelFrame,
                    lineStyle: msg.lineStyle,
                    arrowHead: msg.arrowHead
                ))

                if msg.activateTarget {
                    pushActivation(toIdx, at: cursorY)
                }
                if msg.deactivateTarget {
                    popActivation(fromIdx, at: cursorY)
                }

                cursorY += isSelf ? 40 : 22
            }
        }

        // Close any still-open activations
        for (idx, stack) in activationStacks where !stack.isEmpty {
            for (depth, startY) in stack.enumerated() {
                let rect = CGRect(
                    x: centerX[idx] - 5 + CGFloat(depth) * 4,
                    y: startY,
                    width: 10,
                    height: max(18, cursorY - startY)
                )
                completedActivations.append(MermaidPositionedSequenceActivation(frame: rect))
            }
        }

        let lifelineEndY = cursorY + 12
        let bottomHeaderY = lifelineEndY

        var positionedParticipants: [MermaidPositionedSequenceParticipant] = []
        for i in 0..<participantCount {
            let p = ast.participants[i]
            let info = participantInfos[i]
            let topFrame = CGRect(
                x: centerX[i] - info.size.width / 2,
                y: topMargin,
                width: info.size.width,
                height: topHeaderHeight
            )
            let bottomFrame = CGRect(
                x: centerX[i] - info.size.width / 2,
                y: bottomHeaderY,
                width: info.size.width,
                height: topHeaderHeight
            )
            positionedParticipants.append(MermaidPositionedSequenceParticipant(
                id: p.id,
                labelLines: info.lines,
                kind: p.kind,
                centerX: centerX[i],
                topFrame: topFrame,
                bottomFrame: bottomFrame,
                lifelineTopY: topFrame.maxY,
                lifelineBottomY: bottomFrame.minY
            ))
        }

        let totalHeight = ceil(bottomHeaderY + topHeaderHeight + 20)
        return MermaidPositionedSequence(
            size: CGSize(width: totalWidth, height: totalHeight),
            participants: positionedParticipants,
            activations: completedActivations,
            blocks: completedBlocks,
            messages: messages,
            notes: notes
        )
    }

    // MARK: - Pie Chart Layout

    static func layoutPie(
        _ ast: MermaidPieAST,
        measurer: MermaidTextMeasurer
    ) -> MermaidPositionedPie {
        let total = ast.slices.reduce(0.0) { $0 + $1.value }
        let safeTotal = total > 0 ? total : 1.0

        let titleHeight: CGFloat = (ast.title != nil) ? 34 : 0
        let radius: CGFloat = 92
        let padding: CGFloat = 24
        let center = CGPoint(x: padding + radius, y: padding + titleHeight + radius)

        let legendX = center.x + radius + 28
        let legendLineHeight: CGFloat = 22
        let legendMaxW = ast.slices.map { slice -> CGFloat in
            let pct = Int((slice.value / safeTotal * 100).rounded())
            let text = ast.showData ? "\(slice.label) (\(formatNum(slice.value)), \(pct)%)" : "\(slice.label) (\(pct)%)"
            return measurer.measureText(text, role: .pieLegend, maxWidth: 260).width
        }.max() ?? 100

        let legendHeight = CGFloat(ast.slices.count) * legendLineHeight
        let legendY = max(padding + titleHeight, center.y - legendHeight / 2)

        let totalWidth = ceil(legendX + 20 + legendMaxW + padding)
        let totalHeight = ceil(max(center.y + radius + padding, legendY + legendHeight + padding))

        var currentAngle: CGFloat = -.pi / 2
        var slices: [MermaidPositionedPieSlice] = []
        for (idx, s) in ast.slices.enumerated() {
            let pct = s.value / safeTotal
            let sweep = CGFloat(pct * 2 * .pi)
            slices.append(MermaidPositionedPieSlice(
                label: s.label,
                value: s.value,
                percentage: pct * 100,
                startAngle: currentAngle,
                endAngle: currentAngle + sweep,
                colorIndex: idx
            ))
            currentAngle += sweep
        }

        let titleCenter = ast.title != nil ? CGPoint(x: totalWidth / 2, y: padding + 10) : nil
        return MermaidPositionedPie(
            size: CGSize(width: totalWidth, height: totalHeight),
            title: ast.title,
            titleCenter: titleCenter,
            center: center,
            radius: radius,
            slices: slices,
            showData: ast.showData,
            legendOrigin: CGPoint(x: legendX, y: legendY)
        )
    }

    private static func formatNum(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
