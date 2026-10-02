import SwiftUI
import AnyDiffCore

public struct AgentStartScreenView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public var theme: Theme
    public var workingDirectory: String

    @State private var isAddingCustom: Bool = false
    @State private var customName: String = ""
    @State private var customProfile: String = ""
    @State private var customCommand: String = ""
    @State private var customArgs: String = ""
    @State private var customIcon: String = "terminal"
    @State private var selectedColorName: String = "teal"
    @State private var viewingSessionsPreset: AgentPreset? = nil
    @State private var isViewingRegistry: Bool = false
    @State private var isRegistryHovered: Bool = false
    @State private var isAddCustomHovered: Bool = false

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
        if isViewingRegistry {
            ACPRegistryView(
                coordinator: coordinator,
                theme: theme,
                workingDirectory: workingDirectory,
                onBack: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isViewingRegistry = false
                    }
                }
            )
        } else if let preset = viewingSessionsPreset {
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
                            ForEach(coordinator.agentGroups) { group in
                                AgentCardButton(
                                    group: group,
                                    theme: theme,
                                    onSelect: {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            _ = coordinator.createNewSession(
                                                workingDirectory: workingDirectory,
                                                preset: group.selectedPreset
                                            )
                                        }
                                    },
                                    onSelectProfile: { p in
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            coordinator.selectProfile(preset: p, forBaseId: group.id)
                                        }
                                    },
                                    onAddProfile: {
                                        promptForProfileDuplication(preset: group.basePreset)
                                    },
                                    onDeleteProfile: { p in
                                        confirmDeleteProfile(p)
                                    },
                                    onOpenSessions: {
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            viewingSessionsPreset = group.selectedPreset
                                        }
                                    },
                                    onDeleteAgent: group.basePreset.isCustom ? {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            coordinator.uninstallRegistryAgent(id: group.basePreset.id)
                                        }
                                    } : nil
                                )
                            }

                            // Browse ACP Registry Button
                            browseRegistryButton

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
                        theme: theme,
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
                        .stroke(
                            isAddCustomHovered ? Color(theme.accentColor).opacity(0.7) : Color(theme.gutterForeground).opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [3])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isAddCustomHovered ? Color(theme.accentColor).opacity(0.12) : Color.clear)
                        )
                        .frame(width: 34, height: 34)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isAddCustomHovered ? Color(theme.accentColor) : Color(theme.gutterForeground))
                }

                VStack(alignment: .center, spacing: 2) {
                    Text("Add Custom Agent")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isAddCustomHovered ? Color(theme.accentColor) : Color(theme.foreground))
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(theme.foreground).opacity(isAddCustomHovered ? 0.07 : 0.035))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.14), value: isAddCustomHovered)
        }
        .buttonStyle(.plain)
        .onHover { isAddCustomHovered = $0 }
    }

    @ViewBuilder
    private var browseRegistryButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) {
                isViewingRegistry = true
            }
        }) {
            HStack(spacing: 12) {
                // Globe icon container exactly matching AgentCardButton dimensions (40x40)
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(theme.accentColor).opacity(isRegistryHovered ? 0.18 : 0.10))
                        .frame(width: 40, height: 40)
                    Image(systemName: "globe")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(Color(theme.accentColor))
                }

                // Centered text stack matching AgentCardButton
                VStack(alignment: .center, spacing: 3) {
                    Text("Browse ACP Registry")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("Explore, install, and run certified ACP agents")
                        .font(.system(size: 11))
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.82))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                Spacer(minLength: 4)

                // Right arrow matching AgentCardButton
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isRegistryHovered ? 1.0 : 0.45))
                    .offset(x: isRegistryHovered ? 2 : 0)
                    .animation(.easeOut(duration: 0.15), value: isRegistryHovered)
                    .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(theme.foreground).opacity(isRegistryHovered ? 0.07 : 0.035))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.14), value: isRegistryHovered)
        }
        .buttonStyle(.plain)
        .onHover { isRegistryHovered = $0 }
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
                Text("PROFILE / ACCOUNT (OPTIONAL)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground))

                TextField("e.g. Work, Personal, djvipmax (stored in ~/.anydiff/profiles)", text: $customProfile)
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
                                    .stroke(Color(theme.accentColor), lineWidth: selectedColorName == cName ? 2 : 0)
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
                .stroke(Color(theme.accentColor).opacity(0.4), lineWidth: 1)
        )
    }

    private func saveAndLaunchCustomAgent() {
        let trimmedProfile = customProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = coordinator.addCustomPreset(
            name: customName,
            command: customCommand,
            arguments: customArgs,
            colorName: selectedColorName,
            iconName: customIcon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "terminal" : customIcon.trimmingCharacters(in: .whitespacesAndNewlines),
            profile: trimmedProfile.isEmpty ? nil : trimmedProfile
        )
        customName = ""
        customProfile = ""
        customCommand = ""
        customArgs = ""
        customIcon = "terminal"
        isAddingCustom = false
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = coordinator.createNewSession(workingDirectory: workingDirectory, preset: preset)
        }
    }

    private func promptForProfileDuplication(preset: AgentPreset) {
        let alert = NSAlert()
        alert.messageText = "New Account Profile"
        alert.informativeText = "Enter a profile / account name for '\(preset.name)' (e.g. Work, Personal, djvipmax).\nIsolated storage will be configured at ~/.anydiff/profiles."
        alert.addButton(withTitle: "Create Profile")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "Work"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let duplicated = coordinator.duplicatePreset(preset, profileName: name)
                withAnimation(.easeInOut(duration: 0.2)) {
                    _ = coordinator.createNewSession(workingDirectory: workingDirectory, preset: duplicated)
                }
            }
        }
    }

    private func confirmDeleteProfile(_ preset: AgentPreset) {
        guard let profileName = preset.profile, !profileName.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Profile"
        alert.informativeText = "Are you sure you want to remove the profile '\(profileName)' for '\(preset.name)' from AnyDiff?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            withAnimation(.easeInOut(duration: 0.15)) {
                coordinator.deleteProfile(preset)
            }
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
    let group: AgentGroup
    let theme: Theme
    let onSelect: () -> Void
    let onSelectProfile: (AgentPreset) -> Void
    let onAddProfile: () -> Void
    let onDeleteProfile: (AgentPreset) -> Void
    let onOpenSessions: () -> Void
    var onDeleteAgent: (() -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isSessionsHovered: Bool = false
    @State private var isProfileHovered: Bool = false

    private var preset: AgentPreset {
        group.selectedPreset
    }

    private var presetColor: Color {
        group.basePreset.color
    }

    private var badgeTitle: String {
        group.basePreset.providerName
    }

    private var descriptionText: String {
        group.basePreset.summary.isEmpty ? group.basePreset.effectiveCommand : group.basePreset.summary
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(presetColor.opacity(isHovered ? 0.16 : 0.09))
                    .frame(width: 40, height: 40)
                AgentIconView(icon: group.basePreset.iconName, tintColor: presetColor, size: 20)
            }

            VStack(alignment: .center, spacing: 3) {
                Button(action: onSelect) {
                    VStack(alignment: .center, spacing: 3) {
                        Text(group.basePreset.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(Color(theme.foreground))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)

                        if !group.basePreset.isExecutableAvailable {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8.5))
                                Text("Missing Binary")
                                    .font(.system(size: 9.5, weight: .medium))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.12))
                            )
                            .help("Binary not found on disk. Open ACP Registry to re-download.")
                        } else if !badgeTitle.isEmpty {
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

                HStack(spacing: 6) {
                    profileSelectorMenu

                    Button(action: onOpenSessions) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9.5, weight: .medium))
                            Text("Sessions")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundColor(Color(theme.gutterForeground).opacity(isSessionsHovered ? 1.0 : 0.72))
                        .padding(.horizontal, 5)
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
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 4)

            // Right arrow
            Button(action: onSelect) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isHovered ? 1.0 : 0.45))
                    .offset(x: isHovered ? 2 : 0)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        .contextMenu {
            if let onDeleteAgent = onDeleteAgent {
                Button(role: .destructive, action: onDeleteAgent) {
                    Label("Delete Agent", systemImage: "trash")
                }
            }
        }
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var profileSelectorMenu: some View {
        Button(action: showProfileMenu) {
            HStack(spacing: 4) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 9.5, weight: .medium))
                Text(preset.profileDisplayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .foregroundColor(Color(theme.gutterForeground).opacity(isProfileHovered ? 1.0 : 0.72))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isProfileHovered ? Color(theme.foreground).opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isProfileHovered = $0 }
        .help("Select or create an isolated account profile in ~/.anydiff/profiles")
    }

    private func showProfileMenu() {
        let menu = NSMenu(title: "Account Profiles")
        var targets: [ProfileMenuActionTarget] = []

        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: "Account Profiles"))
        } else {
            let header = NSMenuItem(title: "Account Profiles", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        for p in group.profiles {
            let target = ProfileMenuActionTarget {
                onSelectProfile(p)
            }
            targets.append(target)
            let item = NSMenuItem(
                title: p.profileDisplayName,
                action: #selector(ProfileMenuActionTarget.invoke(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.state = (p.id == preset.id) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let addTarget = ProfileMenuActionTarget {
            onAddProfile()
        }
        targets.append(addTarget)
        let addItem = NSMenuItem(
            title: "New Profile…",
            action: #selector(ProfileMenuActionTarget.invoke(_:)),
            keyEquivalent: ""
        )
        addItem.target = addTarget
        addItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        menu.addItem(addItem)

        if let customProfile = preset.profile, !customProfile.isEmpty {
            menu.addItem(.separator())
            let deleteTarget = ProfileMenuActionTarget {
                onDeleteProfile(preset)
            }
            targets.append(deleteTarget)
            let deleteItem = NSMenuItem(
                title: "Delete Profile \"\(customProfile)\"…",
                action: #selector(ProfileMenuActionTarget.invoke(_:)),
                keyEquivalent: ""
            )
            deleteItem.target = deleteTarget
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(deleteItem)
        }

        withExtendedLifetime(targets) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

private final class ProfileMenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: NSMenuItem) {
        action()
    }
}
