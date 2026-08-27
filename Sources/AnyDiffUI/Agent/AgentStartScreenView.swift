import SwiftUI
import AnyDiffCore

public struct AgentStartScreenView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public var theme: Theme
    public var workingDirectory: String

    @State private var isAddingCustom: Bool = false
    @State private var customName: String = ""
    @State private var customCommand: String = ""
    @State private var customArgs: String = ""
    @State private var customIcon: String = "terminal"
    @State private var selectedColorName: String = "teal"
    @State private var viewingSessionsPreset: AgentPreset? = nil

    private let availableColors = ["white", "black", "gray", "green", "blue", "purple", "orange", "teal", "cyan", "pink", "red"]

    public init(
        coordinator: AgentSessionCoordinator,
        theme: Theme,
        workingDirectory: String
    ) {
        self.coordinator = coordinator
        self.theme = theme
        self.workingDirectory = workingDirectory
    }

    public var body: some View {
        if let preset = viewingSessionsPreset {
            AgentSavedSessionsView(
                preset: preset,
                coordinator: coordinator,
                workingDirectory: workingDirectory,
                theme: theme,
                onBack: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        viewingSessionsPreset = nil
                    }
                },
                onStartNew: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewingSessionsPreset = nil
                        _ = coordinator.createNewSession(
                            workingDirectory: workingDirectory,
                            preset: preset
                        )
                    }
                }
            )
        } else {
            mainStartScreenView
        }
    }

    private var mainStartScreenView: some View {
        VStack(spacing: 0) {
            // Reserve space for window toolbar
            Rectangle()
                .fill(Color(theme.background))
                .frame(height: 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    // If there are existing sessions, show running sessions list
                    if !coordinator.sessions.isEmpty {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            runningSessionsSection
                            Spacer(minLength: 0)
                        }
                    }

                    // Header
                    VStack(spacing: 12) {
                        VStack(spacing: 5) {
                            Text("Choose an Agent")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(Color(theme.foreground))

                            Text("Select an AI agent to inspect diffs, write code, and run commands.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(theme.gutterForeground))
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                                .frame(maxWidth: 320)
                        }
                    }
                    .padding(.top, coordinator.sessions.isEmpty ? 15 : 0)

                    // Agent Cards
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        VStack(spacing: 10) {
                            ForEach(coordinator.allPresets) { preset in
                                AgentCardButton(
                                    preset: preset,
                                    theme: theme,
                                    onSelect: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            _ = coordinator.createNewSession(
                                                workingDirectory: workingDirectory,
                                                preset: preset
                                            )
                                        }
                                    },
                                    onOpenSessions: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            viewingSessionsPreset = preset
                                        }
                                    },
                                    onDelete: preset.isCustom ? {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            coordinator.deleteCustomPreset(id: preset.id)
                                        }
                                    } : nil
                                )
                            }

                            // Add Custom Agent Form / Button
                            if isAddingCustom {
                                customAgentFormView
                            } else {
                                addCustomAgentButton
                            }
                        }
                        .frame(maxWidth: 380)
                        .padding(.horizontal, 16)

                        Spacer(minLength: 0)
                    }

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .background(Color(theme.background))
    }

    @ViewBuilder
    private var runningSessionsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("SESSIONS (\(coordinator.sessions.count))")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))
                Spacer()
            }
            .padding(.horizontal, 4)

            VStack(spacing: 2) {
                ForEach(coordinator.sessions) { session in
                    AgentSessionRowView(
                        session: session,
                        isActive: session.id == coordinator.activeSessionId,
                        canClose: true,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                coordinator.selectSession(id: session.id)
                            }
                        },
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                coordinator.closeSession(id: session.id)
                            }
                        }
                    )
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(theme.foreground).opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(theme.excerptHeaderBorder).opacity(0.5), lineWidth: 1)
            )
        }
        .frame(maxWidth: 380)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var addCustomAgentButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                isAddingCustom = true
            }
        }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(theme.gutterForeground).opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 34, height: 34)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(theme.gutterForeground))
                }

                VStack(alignment: .center, spacing: 2) {
                    Text("Add Custom Agent")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                        .multilineTextAlignment(.center)

                    Text("Run any ACP-compatible command or local server")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(theme.gutterForeground))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(theme.foreground).opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var customAgentFormView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New Custom Agent")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(theme.foreground))
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAddingCustom = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("AGENT NAME")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                TextField("e.g. Qwen 2.5 Coder / Ollama ACP", text: $customName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(theme.background))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(theme.excerptHeaderBorder), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("COMMAND (STDIO / ACP)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                TextField("e.g. npx -y custom-acp or python3", text: $customCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(theme.background))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(theme.excerptHeaderBorder), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("ARGUMENTS (OPTIONAL)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                TextField("e.g. --model gpt-4o --verbose or -m my_acp", text: $customArgs)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color(theme.background))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(theme.excerptHeaderBorder), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("ICON (SLUG, URL OR SF SYMBOL)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(color(for: selectedColorName).opacity(0.16))
                            .frame(width: 32, height: 32)
                        AgentIconView(icon: customIcon.isEmpty ? "terminal" : customIcon, tintColor: color(for: selectedColorName), size: 16)
                    }

                    TextField("e.g. claude, ollama, deepseek, or https://...", text: $customIcon)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color(theme.background))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(theme.excerptHeaderBorder), lineWidth: 1)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("COLOR ACCENT")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                HStack(spacing: 8) {
                    ForEach(availableColors, id: \.self) { cName in
                        Circle()
                            .fill(color(for: cName))
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 0.8)
                            )
                            .overlay(
                                Circle()
                                    .stroke(Color.accentColor, lineWidth: selectedColorName == cName ? 2 : 0)
                            )
                            .scaleEffect(selectedColorName == cName ? 1.15 : 1.0)
                            .onTapGesture {
                                selectedColorName = cName
                            }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isAddingCustom = false
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundColor(Color(theme.gutterForeground))
                .padding(.trailing, 8)

                Button("Save & Launch") {
                    saveAndLaunchCustomAgent()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(theme.foreground).opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
    }

    private func saveAndLaunchCustomAgent() {
        let preset = coordinator.addCustomPreset(
            name: customName,
            command: customCommand,
            arguments: customArgs,
            colorName: selectedColorName,
            iconName: customIcon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "terminal" : customIcon.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        customName = ""
        customCommand = ""
        customArgs = ""
        customIcon = "terminal"
        isAddingCustom = false
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = coordinator.createNewSession(workingDirectory: workingDirectory, preset: preset)
        }
    }

    private func color(for name: String) -> Color {
        switch name {
        case "white": return Color(nsColor: .labelColor)
        case "black": return .black
        case "gray": return .gray
        case "blue": return .blue
        case "purple": return .purple
        case "orange": return .orange
        case "green": return .green
        case "teal": return .teal
        case "cyan": return .cyan
        case "pink": return .pink
        case "red": return .red
        default: return .primary
        }
    }
}

private struct AgentCardButton: View {
    let preset: AgentPreset
    let theme: Theme
    let onSelect: () -> Void
    let onOpenSessions: () -> Void
    var onDelete: (() -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isSessionsHovered: Bool = false

    private var presetColor: Color {
        preset.color
    }

    private var badgeTitle: String {
        preset.providerName
    }

    private var descriptionText: String {
        preset.summary.isEmpty ? preset.effectiveCommand : preset.summary
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(presetColor.opacity(isHovered ? 0.16 : 0.09))
                    .frame(width: 40, height: 40)
                AgentIconView(icon: preset.iconName, tintColor: presetColor, size: 20)
            }

            VStack(alignment: .center, spacing: 2) {
                Button(action: onSelect) {
                    VStack(alignment: .center, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(preset.name)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundColor(Color(theme.foreground))
                                .lineLimit(1)

                            if !badgeTitle.isEmpty {
                                Text(badgeTitle)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(presetColor)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(presetColor.opacity(0.12))
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        Text(descriptionText)
                            .font(.system(size: 11))
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.82))
                            .lineLimit(1)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onOpenSessions) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .medium))
                        Text("Sessions")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(Color(theme.gutterForeground).opacity(isSessionsHovered ? 1.0 : 0.72))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSessionsHovered ? Color(theme.foreground).opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isSessionsHovered = $0 }
                .help("View past sessions for this agent")
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 4)

            // Right arrow / Delete action
            HStack(spacing: 6) {
                if let onDelete = onDelete, isHovered {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red.opacity(0.85))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Delete custom agent")
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isHovered ? 1.0 : 0.45))
                    .offset(x: isHovered ? 2 : 0)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(theme.foreground).opacity(isHovered ? 0.07 : 0.035))
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
