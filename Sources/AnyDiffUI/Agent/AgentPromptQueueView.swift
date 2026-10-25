import SwiftUI
import AnyDiffCore

public struct AgentPromptQueueView: View {
    public let queue: [AgentQueuedMessage]
    public let theme: Theme
    public let accentColor: Color
    public let isAgentBusy: Bool
    public var onEdit: (UUID, String) -> Void
    public var onDelete: (UUID) -> Void
    public var onMove: (UUID, QueueMoveDirection) -> Void
    public var onRunNow: ((UUID) -> Void)?
    public var onClearQueue: (() -> Void)?

    public init(
        queue: [AgentQueuedMessage],
        theme: Theme,
        accentColor: Color,
        isAgentBusy: Bool,
        onEdit: @escaping (UUID, String) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onMove: @escaping (UUID, QueueMoveDirection) -> Void,
        onRunNow: ((UUID) -> Void)? = nil,
        onClearQueue: (() -> Void)? = nil
    ) {
        self.queue = queue
        self.theme = theme
        self.accentColor = accentColor
        self.isAgentBusy = isAgentBusy
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onMove = onMove
        self.onRunNow = onRunNow
        self.onClearQueue = onClearQueue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)

                Text("Prompt Queue")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(theme.foreground).opacity(0.95))

                Text("\(queue.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(Color(theme.gutterForeground))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(theme.foreground).opacity(0.08)))

                if isAgentBusy {
                    Text("• sends after turn")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                }

                Spacer(minLength: 0)

                if let onClearQueue, queue.count > 1 {
                    Button(action: onClearQueue) {
                        Text("Clear all")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Color(theme.gutterForeground))
                    }
                    .buttonStyle(.plain)
                    .help("Clear all queued messages")
                }
            }
            .padding(.horizontal, 4)

            Divider()
                .padding(.horizontal, 2)

            if queue.count > 3 {
                ScrollView(.vertical, showsIndicators: true) {
                    itemsStack
                }
                .frame(maxHeight: 240)
            } else {
                itemsStack
            }
        }
        .padding(10)
        .frame(width: 330)
    }

    private var itemsStack: some View {
        VStack(spacing: 5) {
            ForEach(Array(queue.enumerated()), id: \.element.id) { index, item in
                AgentPromptQueueItemRow(
                    item: item,
                    index: index,
                    totalCount: queue.count,
                    theme: theme,
                    accentColor: accentColor,
                    isAgentBusy: isAgentBusy,
                    onEdit: onEdit,
                    onDelete: onDelete,
                    onMove: onMove,
                    onRunNow: onRunNow
                )
            }
        }
    }
}

private struct AgentPromptQueueItemRow: View {
    let item: AgentQueuedMessage
    let index: Int
    let totalCount: Int
    let theme: Theme
    let accentColor: Color
    let isAgentBusy: Bool
    let onEdit: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onMove: (UUID, QueueMoveDirection) -> Void
    let onRunNow: ((UUID) -> Void)?

    @State private var isEditing: Bool = false
    @State private var editedText: String = ""
    @State private var isHovered: Bool = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                editingView
            } else {
                displayView
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(theme.background))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(theme.inputBackground).opacity(isHovered ? 0.95 : 0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isEditing
                                ? Color(theme.focusColor).opacity(0.8)
                                : (isHovered ? Color(theme.excerptHeaderBorder).opacity(0.9) : Color(theme.excerptHeaderBorder).opacity(0.4)),
                            lineWidth: 1
                        )
                )
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var displayView: some View {
        HStack(alignment: .center, spacing: 9) {
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(index == 0 ? accentColor : Color(theme.gutterForeground))
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill((index == 0 ? accentColor : Color(theme.foreground)).opacity(index == 0 ? 0.16 : 0.08))
                )
                .help(index == 0 ? "Next to send" : "Position \(index + 1)")

            VStack(alignment: .leading, spacing: 2) {
                if !item.images.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(.system(size: 9))
                        Text("\(item.images.count) \(item.images.count == 1 ? "image" : "images")")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(Color(theme.gutterForeground))
                }

                Text(item.text.isEmpty ? "(Image prompt)" : item.text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.foreground).opacity(0.92))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 2) {
                if totalCount > 1 {
                    if index > 0 {
                        actionButton("chevron.up", help: "Move up") { onMove(item.id, .up) }
                    }
                    if index < totalCount - 1 {
                        actionButton("chevron.down", help: "Move down") { onMove(item.id, .down) }
                    }
                }
                if !isAgentBusy, let onRunNow {
                    actionButton("play.fill", help: "Run this prompt now", tint: accentColor) { onRunNow(item.id) }
                }
                actionButton("pencil", help: "Edit prompt") {
                    editedText = item.text
                    isEditing = true
                    isEditorFocused = true
                }
                actionButton("xmark", help: "Remove from queue") { onDelete(item.id) }
            }
            .opacity(isHovered ? 1.0 : 0.0)
        }
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(tint ?? Color(theme.gutterForeground))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Edit prompt...", text: $editedText, axis: .vertical)
                .font(.system(size: 12))
                .lineLimit(1...5)
                .focused($isEditorFocused)
                .textFieldStyle(.plain)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(theme.background))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color(theme.focusColor).opacity(0.7), lineWidth: 1)
                        )
                )
                .onSubmit {
                    saveEdit()
                }
                .onExitCommand {
                    cancelEdit()
                }

            HStack(spacing: 6) {
                Spacer()

                Button("Cancel") {
                    cancelEdit()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color(theme.gutterForeground))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)

                Button(action: {
                    saveEdit()
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Save")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func saveEdit() {
        onEdit(item.id, editedText)
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}
