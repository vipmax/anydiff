import SwiftUI
import AnyDiffCore

struct IdentifiableCommentTarget: Identifiable {
    var id: String { "\(filePath):\(lineNumber)" }
    let filePath: String
    let lineNumber: Int
}

public struct ToolbarHoverButtonStyle: ButtonStyle {
    private let minWidth: CGFloat
    private let minHeight: CGFloat
    @State private var isHovered = false

    public init(minWidth: CGFloat = 22, minHeight: CGFloat = 22) {
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.secondary.opacity(configuration.isPressed ? 0.24 : 0.14) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

public struct AgentToolbarActionButtonStyle: ButtonStyle {
    private let accentColor: Color
    private let isActive: Bool
    @State private var isHovered = false

    public init(accentColor: Color = .accentColor, isActive: Bool = false) {
        self.accentColor = accentColor
        self.isActive = isActive
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = isActive || isHovered || configuration.isPressed

        configuration.label
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .frame(minWidth: 26, minHeight: 24)
            .background(Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accentColor.opacity(isHighlighted ? 0.08 : 0))
            )
            .scaleEffect(isHovered ? 1.02 : 1)
            .shadow(
                color: isHighlighted ? accentColor.opacity(0.16) : Color.clear,
                radius: isHighlighted ? 9 : 5,
                y: isHighlighted ? 2 : 1
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}

struct DiffLayoutToggleIcon: View {
    let mode: DiffLayoutMode

    var body: some View {
        ZStack {
            if mode == .unified {
                VStack(spacing: 2.5) {
                    RoundedRectangle(cornerRadius: 1.8)
                        .fill(Color.secondary)
                        .frame(width: 13, height: 4.5)

                    RoundedRectangle(cornerRadius: 1.8)
                        .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.0)
                        .frame(width: 13, height: 4.5)
                }
                .frame(width: 16, height: 16)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                HStack(spacing: 2.5) {
                    RoundedRectangle(cornerRadius: 1.8)
                        .strokeBorder(Color.secondary.opacity(0.7), lineWidth: 1.0)
                        .frame(width: 4.5, height: 13)

                    RoundedRectangle(cornerRadius: 1.8)
                        .fill(Color.secondary)
                        .frame(width: 4.5, height: 13)
                }
                .frame(width: 16, height: 16)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: mode)
    }
}
