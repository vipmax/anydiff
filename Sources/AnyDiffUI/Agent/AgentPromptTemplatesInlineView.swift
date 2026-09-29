import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentPromptTemplatesInlineView: View {
    @ObservedObject public var store: AgentPromptTemplateStore
    public var theme: Theme
    public var accentColor: Color
    public var onDone: () -> Void

    @State private var editingTemplateId: String? = nil
    @State private var isCreatingNew: Bool = false
    @State private var formTitle: String = ""
    @State private var formPrompt: String = ""
    @State private var hoveredTemplateId: String? = nil
    @State private var isBackHovered: Bool = false
    @State private var showResetConfirmation: Bool = false

    public init(
        store: AgentPromptTemplateStore = .shared,
        theme: Theme,
        accentColor: Color = .accentColor,
        onDone: @escaping () -> Void
    ) {
        self.store = store
        self.theme = theme
        self.accentColor = accentColor
        self.onDone = onDone
    }

    private var isFormActive: Bool {
        isCreatingNew || editingTemplateId != nil
    }

    public var body: some View {
        VStack(spacing: 8) {
            headerView

            if isFormActive {
                editorFormCard
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    ))
            } else {
                templatesList
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 430)
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: isFormActive ? "pencil" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)

                Text(isFormActive ? (editingTemplateId == nil ? "NEW TEMPLATE" : "EDIT TEMPLATE") : "CUSTOMIZE TEMPLATES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))
                    .tracking(0.5)
            }

            Spacer()

            if isFormActive {
                Button(action: cancelForm) {
                    Text("Back to List")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isBackHovered ? Color(theme.foreground) : Color(theme.gutterForeground))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isBackHovered ? Color(theme.foreground).opacity(0.08) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isBackHovered = $0 }
            } else {
                if showResetConfirmation {
                    HStack(spacing: 4) {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                store.resetToDefaults()
                                showResetConfirmation = false
                            }
                        }) {
                            Text("Reset?")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)

                        Button(action: { showResetConfirmation = false }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(theme.gutterForeground))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                } else {
                    Button(action: { showResetConfirmation = true }) {
                        Text("Reset")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.85))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default templates")
                }

                Button(action: startCreating) {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(accentColor.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("Add a new prompt template")

                Button(action: onDone) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Done")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(accentColor, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Return to action cards")
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    // MARK: - Templates List
    private var templatesList: some View {
        VStack(spacing: 6) {
            if store.templates.isEmpty {
                VStack(spacing: 8) {
                    Text("No templates configured")
                        .font(.system(size: 12))
                        .foregroundColor(Color(theme.gutterForeground))

                    Button("Reset to Defaults") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.resetToDefaults()
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(accentColor)
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(theme.foreground).opacity(0.02))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color(theme.excerptHeaderBorder).opacity(0.4), lineWidth: 1)
                        )
                )
            } else {
                ForEach(Array(store.templates.enumerated()), id: \.element.id) { index, template in
                    templateEditableRow(template: template, index: index)
                }
            }
        }
    }

    @ViewBuilder
    private func templateEditableRow(template: AgentPromptTemplate, index: Int) -> some View {
        let isHovered = hoveredTemplateId == template.id

        HStack(spacing: 12) {
            // Title & prompt preview (clicking here starts editing)
            Button(action: {
                startEditing(template)
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(theme.foreground))
                        .lineLimit(1)

                    Text(template.prompt)
                        .font(.system(size: 11))
                        .foregroundColor(Color(theme.gutterForeground))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to edit template")

            // Reorder and edit/delete action buttons
            HStack(spacing: 4) {
                if index > 0 {
                    actionButton(icon: "arrow.up", help: "Move up") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.moveTemplate(id: template.id, direction: .up)
                        }
                    }
                }

                if index < store.templates.count - 1 {
                    actionButton(icon: "arrow.down", help: "Move down") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.moveTemplate(id: template.id, direction: .down)
                        }
                    }
                }

                actionButton(icon: "pencil", help: "Edit template") {
                    startEditing(template)
                }

                actionButton(icon: "trash", help: "Delete template", isDestructive: true) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.deleteTemplate(id: template.id)
                    }
                }
            }
            .opacity(isHovered ? 1 : 0.7)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accentColor.opacity(isHovered ? 0.04 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(theme.excerptHeaderBorder).opacity(isHovered ? 0.8 : 0.5), lineWidth: 1)
                )
        )
        .onHover { hovering in
            hoveredTemplateId = hovering ? template.id : nil
        }
    }

    @ViewBuilder
    private func actionButton(
        icon: String,
        help: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isDestructive ? Color.red.opacity(0.85) : Color(theme.foreground).opacity(0.8))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isDestructive ? Color.red.opacity(0.08) : Color(theme.foreground).opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Editor Form Card
    private var editorFormCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title input
            VStack(alignment: .leading, spacing: 4) {
                Text("NAME")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                TextField("e.g. Write unit tests", text: $formTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(theme.foreground).opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(theme.foreground).opacity(0.12), lineWidth: 1)
                    )
            }

            // Prompt text input
            VStack(alignment: .leading, spacing: 4) {
                Text("PROMPT TEXT")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                TextEditor(text: $formPrompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(theme.foreground).opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(theme.foreground).opacity(0.12), lineWidth: 1)
                    )
            }

            // Form actions
            HStack {
                Button("Cancel", action: cancelForm)
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundColor(Color(theme.gutterForeground))

                Spacer()

                Button(action: saveForm) {
                    Text(editingTemplateId == nil ? "Add Template" : "Save Changes")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            isFormValid ? accentColor : Color.gray.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isFormValid)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(theme.foreground).opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(theme.foreground).opacity(0.1), lineWidth: 1)
                )
        )
    }

    private var isFormValid: Bool {
        !formTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !formPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startCreating() {
        withAnimation(.easeInOut(duration: 0.18)) {
            editingTemplateId = nil
            formTitle = ""
            formPrompt = ""
            isCreatingNew = true
        }
    }

    private func startEditing(_ template: AgentPromptTemplate) {
        withAnimation(.easeInOut(duration: 0.18)) {
            editingTemplateId = template.id
            formTitle = template.title
            formPrompt = template.prompt
            isCreatingNew = false
        }
    }

    private func cancelForm() {
        withAnimation(.easeInOut(duration: 0.18)) {
            editingTemplateId = nil
            isCreatingNew = false
            formTitle = ""
            formPrompt = ""
        }
    }

    private func saveForm() {
        guard isFormValid else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            if let editingId = editingTemplateId {
                store.updateTemplate(
                    id: editingId,
                    title: formTitle,
                    prompt: formPrompt
                )
            } else {
                store.addTemplate(
                    title: formTitle,
                    prompt: formPrompt
                )
            }
            cancelForm()
        }
    }
}
