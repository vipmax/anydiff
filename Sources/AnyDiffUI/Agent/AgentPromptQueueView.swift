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
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)

                Text("Queued Prompts (\(queue.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.gutterForeground))

                if isAgentBusy {
                    Text("• will send after current turn")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                }

                Spacer(minLength: 0)

                if let onClearQueue, queue.count > 1 {
                    Button(action: onClearQueue) {
                        Text("Clear All")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Clear all queued messages")
                }
            }
            .padding(.horizontal, 4)

            // Queue items list
            if queue.count > 3 {
                ScrollView(.vertical, showsIndicators: true) {
                    itemsStack
                }
                .frame(maxHeight: 180)
            } else {
                itemsStack
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(theme.gutterBackground).opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(theme.excerptHeaderBorder).opacity(0.65), lineWidth: 1)
                )
        )
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
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(theme.inputBackground).opacity(isHovered ? 0.95 : 0.75))
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
        HStack(alignment: .top, spacing: 8) {
            // Position Badge (#1 Next, #2, etc.)
            HStack(spacing: 3) {
                Text("#\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(index == 0 ? accentColor : Color(theme.gutterForeground))

                if index == 0 {
                    Text("Next")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(accentColor)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((index == 0 ? accentColor : Color(theme.gutterForeground)).opacity(0.12))
            )

            // Content preview (text + attachments)
            VStack(alignment: .leading, spacing: 2) {
                if !item.images.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(.system(size: 9))
                        Text("\(item.images.count) \(item.images.count == 1 ? "image" : "images")")
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundColor(Color(theme.gutterForeground))
                }

                Text(item.text.isEmpty ? "(Image prompt)" : item.text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.foreground).opacity(0.92))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            // Action buttons
            HStack(spacing: 3) {
                // Reorder buttons (if multiple items)
                if totalCount > 1 {
                    if index > 0 {
                        Button(action: { onMove(item.id, .up) }) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(theme.gutterForeground))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Move Up")
                    }

                    if index < totalCount - 1 {
                        Button(action: { onMove(item.id, .down) }) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Color(theme.gutterForeground))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Move Down")
                    }
                }

                // Run Now button (when agent is idle)
                if !isAgentBusy, let onRunNow {
                    Button(action: { onRunNow(item.id) }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(accentColor)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Run this prompt now")
                }

                // Edit button
                Button(action: {
                    editedText = item.text
                    isEditing = true
                    isEditorFocused = true
                }) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(theme.gutterForeground))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit prompt")

                // Delete button
                Button(action: {
                    onDelete(item.id)
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.85))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }
            .opacity(isHovered ? 1.0 : 0.65)
        }
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
