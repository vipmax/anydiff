import SwiftUI
import AnyDiffCore

public struct AgentStartScreenView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public var slot: PanelSlot = .right
    public var theme: Theme
    public var workingDirectory: String
    public var isGitRepository: Bool = false
    public var currentBranch: String = ""
    public var worktrees: [GitWorktree] = []
    public var repoName: String = ""
    public var onSelectWorktree: ((GitWorktree) -> Void)? = nil

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
    @State private var workInNewWorktree: Bool = false
    @State private var selectedWorktreePath: String? = nil
    @State private var selectedNavItem: AgentStartScreenNavItem? = nil
    @State private var keyboardFocusRequest: Int = 0

    private var targetWorkingDirectory: String {
        if let selectedWorktreePath, !selectedWorktreePath.isEmpty {
            return selectedWorktreePath
        }
        return workingDirectory
    }

    private var selectedWorktreeBranch: String? {
        let resolvedTarget = URL(fileURLWithPath: targetWorkingDirectory).resolvingSymlinksInPath().path
        if let match = worktrees.first(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == resolvedTarget
        }), let branch = match.branch, !branch.isEmpty {
            return branch
        }
        return currentBranch.isEmpty ? nil : currentBranch
    }

    private let availableColors = ["white", "black", "gray", "green", "blue", "purple", "orange", "teal", "cyan", "pink", "red"]

    public init(
        coordinator: AgentSessionCoordinator,
        slot: PanelSlot = .right,
        theme: Theme,
        workingDirectory: String,
        isGitRepository: Bool = false,
        currentBranch: String = "",
        worktrees: [GitWorktree] = [],
        repoName: String = "",
        onSelectWorktree: ((GitWorktree) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.slot = slot
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.isGitRepository = isGitRepository
        self.currentBranch = currentBranch
        self.worktrees = worktrees
        self.repoName = repoName
        self.onSelectWorktree = onSelectWorktree
    }

    public var body: some View {
        Group {
            if isViewingRegistry {
                ACPRegistryView(
                    coordinator: coordinator,
                    theme: theme,
                    workingDirectory: targetWorkingDirectory,
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
                    slot: slot,
                    workingDirectory: targetWorkingDirectory,
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
                                workingDirectory: targetWorkingDirectory,
                                preset: preset,
                                for: slot
                            )
                        }
                    }
                )
            } else {
                mainStartScreenView
            }
        }
        .onChange(of: workingDirectory) { _ in
            selectedWorktreePath = nil
            workInNewWorktree = false
        }
    }

    private var mainStartScreenView: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width)
            let minContentWidth: CGFloat = 280
            let maxContentWidth: CGFloat = 380
            let horizontalPadding: CGFloat = 14

            let isOverflowing = (availableWidth - horizontalPadding * 2) < minContentWidth
            let contentWidth = isOverflowing ? minContentWidth : min(availableWidth - horizontalPadding * 2, maxContentWidth)

            ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                HStack(spacing: 0) {
                    if !isOverflowing {
                        Spacer(minLength: 0)
                    }

                    VStack(spacing: 20) {
                        // If there are existing sessions, show running sessions list
                        if !coordinator.sessions.isEmpty {
                            runningSessionsSection
                        }

                        // Header
                        VStack(spacing: 12) {
                            VStack(spacing: 4) {
                                Text("Choose an Agent")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(Color(theme.foreground))
                                    .lineLimit(1)

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
                        VStack(spacing: 10) {
                            ForEach(coordinator.agentGroups) { group in
                                let cardNavItem = AgentStartScreenNavItem.agent(group.id)
                                AgentCardButton(
                                    group: group,
                                    theme: theme,
                                    workingDirectory: targetWorkingDirectory,
                                    isGitRepository: isGitRepository,
                                    currentBranch: currentBranch,
                                    worktrees: worktrees,
                                    repoName: repoName,
                                    workInNewWorktree: workInNewWorktree,
                                    isKeyboardSelected: selectedNavItem == cardNavItem,
                                    onSelect: {
                                        selectAgentGroup(group)
                                    },
                                    onSelectWorktree: { wt in
                                        workInNewWorktree = false
                                        selectedWorktreePath = wt.path
                                        onSelectWorktree?(wt)
                                    },
                                    onToggleNewWorktree: {
                                        workInNewWorktree.toggle()
                                    },
                                    onSelectProfile: { p in
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            coordinator.selectProfile(preset: p, forBaseId: group.id)
                                        }
                                    },
                                    onAddProfile: {
                                        promptForProfileDuplication(preset: group.basePreset)
                                    },
                                    onRenameProfile: { p in
                                        promptForProfileRename(p)
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
                                .id(cardNavItem)
                            }

                            // Browse ACP Registry Button
                            browseRegistryButton
                                .id(AgentStartScreenNavItem.browseRegistry)

                            // Add Custom Agent Form / Button
                            if isAddingCustom {
                                customAgentFormView
                            } else {
                                addCustomAgentButton
                                    .id(AgentStartScreenNavItem.addCustom)
                            }
                        }

                        Spacer(minLength: 20)
                    }
                    .frame(width: contentWidth)
                    .padding(.leading, isOverflowing ? horizontalPadding : 0)

                    if !isOverflowing {
                        Spacer(minLength: 0)
                    }
                }
                .frame(minWidth: availableWidth, alignment: .leading)
                .padding(.vertical, 16)
            }
            .clipped()
            .onChange(of: selectedNavItem) { item in
                if let item {
                    withAnimation(.easeOut(duration: 0.12)) {
                        scrollProxy.scrollTo(item)
                    }
                }
            }
            }
        }
        .background(
            ZStack {
                Color(theme.background)
                AgentStartScreenKeyBridge(
                    isAddingCustom: isAddingCustom,
                    focusRequestToken: keyboardFocusRequest,
                    onMoveSelection: { delta in
                        moveNavSelection(by: delta)
                    },
                    onActivateSelection: {
                        activateNavSelection()
                    },
                    onEscape: {
                        handleStartScreenEscape()
                    }
                )
            }
        )
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("anyDiffAgentStartScreenKeyboardFocus"))) { notif in
            if let targetSlot = notif.object as? PanelSlot, targetSlot != slot {
                return
            }
            selectInitialNavItemForKeyboard()
            keyboardFocusRequest &+= 1
        }
        .onChange(of: coordinator.sessions.map(\.id)) { _ in
            validateNavSelection()
        }
        .onChange(of: coordinator.agentGroups.map(\.id)) { _ in
            validateNavSelection()
        }
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
                    let sessionNavItem = AgentStartScreenNavItem.session(session.id)
                    AgentSessionRowView(
                        session: session,
                        isActive: session.id == coordinator.activeSession(for: slot)?.id,
                        isKeyboardSelected: selectedNavItem == sessionNavItem,
                        canClose: true,
                        theme: theme,
                        worktrees: worktrees,
                        fallbackWorkingDirectory: workingDirectory,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                coordinator.selectSession(id: session.id, for: slot)
                            }
                        },
                        onClose: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                coordinator.closeSession(id: session.id)
                            }
                        }
                    )
                    .id(sessionNavItem)
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
        .frame(maxWidth: .infinity)
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
                let boxSize: CGFloat = 44
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            isAddCustomHovered ? Color(theme.accentColor).opacity(0.7) : Color(theme.gutterForeground).opacity(0.4),
                            style: StrokeStyle(lineWidth: 1, dash: [3])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isAddCustomHovered ? Color(theme.accentColor).opacity(0.12) : Color.clear)
                        )
                        .frame(width: boxSize, height: boxSize)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isAddCustomHovered ? Color(theme.accentColor) : Color(theme.gutterForeground))
                }

                VStack(alignment: .center, spacing: 3) {
                    Text("Add Custom Agent")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Text("Run any ACP-compatible command or local server")
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(theme.gutterForeground))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(theme.foreground).opacity((isAddCustomHovered || selectedNavItem == .addCustom) ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selectedNavItem == .addCustom ? Color(theme.accentColor).opacity(0.75) : Color.clear, lineWidth: 1.5)
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
                let boxSize: CGFloat = 44
                ZStack {
                    Image(systemName: "globe")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(Color(theme.accentColor))
                }
                .frame(width: boxSize, height: boxSize)

                // Centered text stack matching AgentCardButton
                VStack(alignment: .center, spacing: 3) {
                    Text("Browse ACP Registry")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                        .lineLimit(1)
                        .truncationMode(.tail)
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
                let isRegistrySelected = isRegistryHovered || selectedNavItem == .browseRegistry
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isRegistrySelected ? 1.0 : 0.45))
                    .offset(x: isRegistrySelected ? 2 : 0)
                    .animation(.easeOut(duration: 0.15), value: isRegistrySelected)
                    .frame(width: 20, height: 20)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(theme.foreground).opacity((isRegistryHovered || selectedNavItem == .browseRegistry) ? 0.07 : 0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selectedNavItem == .browseRegistry ? Color(theme.accentColor).opacity(0.75) : Color.clear, lineWidth: 1.5)
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
            _ = coordinator.createNewSession(workingDirectory: workingDirectory, preset: preset, for: slot)
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
                    _ = coordinator.createNewSession(workingDirectory: workingDirectory, preset: duplicated, for: slot)
                }
            }
        }
    }

    private func promptForProfileRename(_ preset: AgentPreset) {
        guard let currentProfile = preset.profile, !currentProfile.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Account Profile"
        alert.informativeText = "Enter a new profile name for '\(currentProfile)'."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = currentProfile
        input.placeholderString = "Work"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty, newName != currentProfile else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                if let updated = coordinator.renameProfile(preset, to: newName) {
                    if updated.id != preset.id {
                        AgentAvatarProvider.migrateAgentAvatar(from: preset.id, to: updated.id)
                    }
                } else {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Cannot Rename Profile"
                    errorAlert.informativeText = "A profile named '\(newName)' already exists for '\(preset.name)'."
                    errorAlert.alertStyle = .warning
                    errorAlert.addButton(withTitle: "OK")
                    errorAlert.runModal()
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

    private var navItems: [AgentStartScreenNavItem] {
        var items: [AgentStartScreenNavItem] = coordinator.sessions.map { .session($0.id) }
        items.append(contentsOf: coordinator.agentGroups.map { .agent($0.id) })
        items.append(.browseRegistry)
        if !isAddingCustom {
            items.append(.addCustom)
        }
        return items
    }

    private func selectInitialNavItemForKeyboard() {
        let items = navItems
        guard !items.isEmpty else {
            selectedNavItem = nil
            return
        }
        if let active = coordinator.activeSession(for: slot),
           items.contains(.session(active.id)) {
            selectedNavItem = .session(active.id)
        } else if let firstAgent = coordinator.agentGroups.first {
            selectedNavItem = .agent(firstAgent.id)
        } else {
            selectedNavItem = items.first
        }
    }

    private func validateNavSelection() {
        if let current = selectedNavItem, !navItems.contains(current) {
            selectedNavItem = navItems.first
        }
    }

    private func moveNavSelection(by delta: Int) {
        let items = navItems
        guard !items.isEmpty else {
            selectedNavItem = nil
            return
        }
        guard let current = selectedNavItem, let idx = items.firstIndex(of: current) else {
            selectedNavItem = delta >= 0 ? items.first : items.last
            return
        }
        let nextIdx = (idx + delta + items.count) % items.count
        selectedNavItem = items[nextIdx]
    }

    private func activateNavSelection() {
        let target = selectedNavItem ?? navItems.first
        guard let target else { return }
        selectedNavItem = target

        switch target {
        case .session(let id):
            withAnimation(.easeInOut(duration: 0.18)) {
                coordinator.selectSession(id: id, for: slot)
            }
        case .agent(let groupId):
            if let group = coordinator.agentGroups.first(where: { $0.id == groupId }) {
                selectAgentGroup(group)
            }
        case .browseRegistry:
            withAnimation(.easeInOut(duration: 0.18)) {
                isViewingRegistry = true
            }
        case .addCustom:
            withAnimation(.easeInOut(duration: 0.18)) {
                isAddingCustom = true
            }
        }
    }

    private func handleStartScreenEscape() {
        if isAddingCustom {
            withAnimation(.easeInOut(duration: 0.15)) {
                isAddingCustom = false
            }
            keyboardFocusRequest &+= 1
        } else if selectedNavItem != nil {
            selectedNavItem = nil
        }
    }

    private func selectAgentGroup(_ group: AgentGroup) {
        let shouldCreateNewWorktree = isGitRepository && workInNewWorktree
        let baseBranch = selectedWorktreeBranch
        let chosenWorkingDirectory = targetWorkingDirectory
        withAnimation(.easeInOut(duration: 0.2)) {
            _ = coordinator.createNewSession(
                workingDirectory: chosenWorkingDirectory,
                preset: group.selectedPreset,
                pendingNewWorktree: shouldCreateNewWorktree,
                pendingNewWorktreeBaseBranch: shouldCreateNewWorktree ? baseBranch : nil,
                for: slot
            )
            workInNewWorktree = false
            selectedWorktreePath = nil
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
    let workingDirectory: String
    let isGitRepository: Bool
    let currentBranch: String
    let worktrees: [GitWorktree]
    let repoName: String
    let workInNewWorktree: Bool
    var isKeyboardSelected: Bool = false
    let onSelect: () -> Void
    let onSelectWorktree: (GitWorktree) -> Void
    let onToggleNewWorktree: () -> Void
    let onSelectProfile: (AgentPreset) -> Void
    let onAddProfile: () -> Void
    let onRenameProfile: (AgentPreset) -> Void
    let onDeleteProfile: (AgentPreset) -> Void
    let onOpenSessions: () -> Void
    var onDeleteAgent: (() -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var isSessionsHovered: Bool = false
    @State private var isProfileHovered: Bool = false
    @State private var isWorkInHovered: Bool = false
    @State private var isWorkInPopoverPresented: Bool = false
    @State private var worktreeSearch: String = ""
    @State private var avatarToken: UInt64 = 0

    private var customAvatar: NSImage? {
        _ = avatarToken
        if let img = AgentAvatarProvider.customAgentAvatarImage(for: group.selectedPreset.id) {
            return img
        }
        if let img = AgentAvatarProvider.customAgentAvatarImage(for: group.basePreset.id) {
            return img
        }
        for p in group.profiles {
            if let img = AgentAvatarProvider.customAgentAvatarImage(for: p.id) {
                return img
            }
        }
        return nil
    }

    private var preset: AgentPreset {
        group.selectedPreset
    }

    private var presetColor: Color {
        group.basePreset.color
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                AgentIconView(
                    icon: group.basePreset.iconName,
                    agentId: group.selectedPreset.id,
                    fallbackBaseId: group.basePreset.id,
                    tintColor: presetColor,
                    size: customAvatar == nil ? 26 : 44
                )
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .center, spacing: 5) {
                Button(action: onSelect) {
                    VStack(alignment: .center, spacing: 3) {
                        Text(group.basePreset.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(Color(theme.foreground))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .center)

                        if !group.basePreset.isExecutableAvailable {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                                Text("Missing Binary")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(Color.orange.opacity(0.12))
                            )
                            .help("Binary not found on disk. Open ACP Registry to re-download.")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: 8) {
                    profileSelectorMenu

                    Button(action: onOpenSessions) {
                        HStack(spacing: 3.5) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9.5, weight: .medium))
                            Text("Sessions")
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
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
                    .fixedSize()
                    .onHover { isSessionsHovered = $0 }
                    .help("View past sessions for this agent")
                }
                .frame(maxWidth: .infinity, alignment: .center)

                if isGitRepository {
                    workInSelectorButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 4)

            // Right arrow
            Button(action: onSelect) {
                let isCardActive = isHovered || isKeyboardSelected
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isCardActive ? 1.0 : 0.45))
                    .offset(x: isCardActive ? 2 : 0)
                    .animation(.easeOut(duration: 0.15), value: isCardActive)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(theme.foreground).opacity((isHovered || isKeyboardSelected) ? 0.07 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isKeyboardSelected ? presetColor.opacity(0.75) : Color.clear, lineWidth: 1.5)
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
        .onReceive(NotificationCenter.default.publisher(for: AgentAvatarProvider.avatarDidChangeNotification)) { _ in
            avatarToken &+= 1
        }
    }

    private func isCurrentWorktree(_ wt: GitWorktree) -> Bool {
        let currentResolved = URL(fileURLWithPath: workingDirectory).resolvingSymlinksInPath().path
        let targetResolved = URL(fileURLWithPath: wt.path).resolvingSymlinksInPath().path
        return currentResolved == targetResolved
    }

    private var activeWorktree: GitWorktree? {
        worktrees.first(where: { isCurrentWorktree($0) })
    }

    private var filteredWorktrees: [GitWorktree] {
        let query = worktreeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return worktrees }
        return worktrees.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) ||
            $0.folderName.localizedCaseInsensitiveContains(query) ||
            $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var workInSelectorButton: some View {
        let currentLabel = activeWorktree?.displayTitle ?? (currentBranch.isEmpty ? "HEAD" : currentBranch)
        let labelText = workInNewWorktree ? "Work in: New worktree" : "Work in: \(currentLabel)"

        Button {
            worktreeSearch = ""
            isWorkInPopoverPresented.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: workInNewWorktree ? "square.stack.3d.up" : "arrow.triangle.branch")
                    .font(.system(size: 9.5, weight: .medium))
                Text(labelText)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .foregroundColor(
                workInNewWorktree
                    ? presetColor
                    : Color(theme.gutterForeground).opacity(isWorkInHovered || isWorkInPopoverPresented ? 1.0 : 0.72)
            )
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        (isWorkInHovered || isWorkInPopoverPresented)
                            ? (workInNewWorktree ? presetColor.opacity(0.12) : Color(theme.foreground).opacity(0.08))
                            : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .onHover { isWorkInHovered = $0 }
        .help(workInNewWorktree
            ? "Runs agent in a new isolated git worktree under ~/.anydiff/worktrees (Click to change)"
            : "Work in: \(currentLabel) (Click to switch worktree or create a new one)")
        .popover(isPresented: $isWorkInPopoverPresented, arrowEdge: .bottom) {
            workInPopoverView
        }
    }

    @ViewBuilder
    private var workInPopoverView: some View {
        let folderDisplayName = repoName.isEmpty
            ? URL(fileURLWithPath: workingDirectory).lastPathComponent
            : repoName

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text(folderDisplayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("Work in")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if worktrees.count > 8 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    TextField("Filter worktrees...", text: $worktreeSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 8)
            }

            if !filteredWorktrees.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredWorktrees) { wt in
                            let isSelected = !workInNewWorktree && isCurrentWorktree(wt)
                            let shortPath = (wt.path as NSString).abbreviatingWithTildeInPath

                            Button {
                                onSelectWorktree(wt)
                                isWorkInPopoverPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: wt.isMain ? "folder" : "square.stack.3d.up")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(isSelected ? presetColor : .secondary)
                                        .frame(width: 14)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(wt.displayTitle)
                                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(shortPath)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer(minLength: 8)

                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10.5, weight: .bold))
                                            .foregroundColor(presetColor)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? Color.primary.opacity(0.08) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: 210)
            } else {
                Text(worktreeSearch.isEmpty ? "No worktrees found" : "No matching worktrees")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }

            Divider()
                .padding(.horizontal, 8)

            Button {
                onToggleNewWorktree()
                isWorkInPopoverPresented = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(workInNewWorktree ? presetColor : .secondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("Work in a New Worktree")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Keeps your checkout untouched")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 8)

                    if workInNewWorktree {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(presetColor)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(workInNewWorktree ? presetColor.opacity(0.11) : Color.primary.opacity(0.04))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
        .frame(width: 276)
    }

    @ViewBuilder
    private var profileSelectorMenu: some View {
        Button(action: showProfileMenu) {
            HStack(spacing: 3.5) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 9.5, weight: .medium))
                Text(preset.profileDisplayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .lineLimit(1)
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
            let renameTarget = ProfileMenuActionTarget {
                onRenameProfile(preset)
            }
            targets.append(renameTarget)
            let renameItem = NSMenuItem(
                title: "Rename Profile…",
                action: #selector(ProfileMenuActionTarget.invoke(_:)),
                keyEquivalent: ""
            )
            renameItem.target = renameTarget
            renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
            menu.addItem(renameItem)

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


// MARK: - Start Screen Keyboard Navigation

private enum AgentStartScreenNavItem: Hashable {
    case session(UUID)
    case agent(String)
    case browseRegistry
    case addCustom
}

private struct AgentStartScreenKeyBridge: NSViewRepresentable {
    let isAddingCustom: Bool
    let focusRequestToken: Int
    let onMoveSelection: (Int) -> Void
    let onActivateSelection: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AgentStartScreenKeyHostView {
        let view = AgentStartScreenKeyHostView()
        view.isAddingCustom = isAddingCustom
        view.onMoveSelection = onMoveSelection
        view.onActivateSelection = onActivateSelection
        view.onEscape = onEscape
        context.coordinator.lastFocusToken = focusRequestToken
        return view
    }

    func updateNSView(_ nsView: AgentStartScreenKeyHostView, context: Context) {
        nsView.isAddingCustom = isAddingCustom
        nsView.onMoveSelection = onMoveSelection
        nsView.onActivateSelection = onActivateSelection
        nsView.onEscape = onEscape
        if context.coordinator.lastFocusToken != focusRequestToken {
            context.coordinator.lastFocusToken = focusRequestToken
            nsView.requestPanelFocus()
        }
    }

    static func dismantleNSView(_ nsView: AgentStartScreenKeyHostView, coordinator: Coordinator) {
        nsView.removeMonitors()
    }

    final class Coordinator {
        var lastFocusToken: Int = 0
    }
}

private final class AgentStartScreenKeyHostView: NSView {
    var isAddingCustom: Bool = false
    var onMoveSelection: ((Int) -> Void)?
    var onActivateSelection: (() -> Void)?
    var onEscape: (() -> Void)?

    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        // Prevent NSBeep when this view is firstResponder
        switch event.keyCode {
        case 123, 124, 125, 126, 36, 76, 49, 53:
            return
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            installMonitors()
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                if self.shouldClaimInitialFocus(in: window) {
                    window.makeFirstResponder(self)
                }
            }
        } else {
            removeMonitors()
        }
    }

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func requestPanelFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow else { return }
            if !self.isAddingCustom {
                window.makeFirstResponder(self)
            }
        }
    }

    func removeMonitors() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func shouldClaimInitialFocus(in window: NSWindow) -> Bool {
        guard window.isKeyWindow, window.attachedSheet == nil, !isAddingCustom else { return false }
        guard let responder = window.firstResponder else { return true }
        if responder === window || responder === window.contentView {
            return true
        }
        if let view = responder as? NSView, view.window == nil {
            return true
        }
        return false
    }

    private func installMonitors() {
        guard keyMonitor == nil && mouseMonitor == nil else { return }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let panelRect = self.convert(self.bounds, to: nil)
            guard !panelRect.isEmpty, panelRect.contains(event.locationInWindow) else {
                return event
            }
            let responderBefore = window.firstResponder
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                let responderAfter = window.firstResponder
                if !self.isResponderInsideStartScreen(responderAfter, in: window) {
                    if responderAfter === responderBefore || responderAfter == nil || responderAfter === window {
                        window.makeFirstResponder(self)
                    }
                }
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  window.isKeyWindow,
                  window.attachedSheet == nil else {
                return event
            }

            // Skip when user is typing in another panel or modal
            guard self.isResponderInsideStartScreen(window.firstResponder, in: window) || self.shouldClaimInitialFocus(in: window) else {
                return event
            }

            // If user is typing inside custom agent form text fields, only allow Esc to close the form
            if let textView = window.firstResponder as? NSTextView {
                if event.keyCode == 53 && !textView.hasMarkedText() && self.isAddingCustom {
                    self.onEscape?()
                    return nil
                }
                return event
            }
            if window.firstResponder is NSTextField {
                if event.keyCode == 53 && self.isAddingCustom {
                    self.onEscape?()
                    return nil
                }
                return event
            }

            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty else { return event }

            switch event.keyCode {
            case 126: // Up arrow
                self.onMoveSelection?(-1)
                return nil
            case 125: // Down arrow
                self.onMoveSelection?(1)
                return nil
            case 123, 124: // Left / Right arrows
                return nil
            case 36, 76, 49: // Return, Numpad Enter, Space
                self.onActivateSelection?()
                return nil
            case 53: // Escape
                self.onEscape?()
                return nil
            default:
                return event
            }
        }
    }

    private func isResponderInsideStartScreen(_ responder: NSResponder?, in window: NSWindow) -> Bool {
        guard let view = responder as? NSView else { return false }
        if view === self { return true }
        if view === window.contentView { return false }

        var rootScrollOrView = view
        while let sv = rootScrollOrView.enclosingScrollView {
            rootScrollOrView = sv
        }

        let panelRect = self.convert(self.bounds, to: nil)
        let viewRect = rootScrollOrView.convert(rootScrollOrView.bounds, to: nil)
        guard !panelRect.isEmpty, !viewRect.isEmpty else { return false }
        let toleranceRect = panelRect.insetBy(dx: -2, dy: -2)
        return toleranceRect.contains(viewRect)
    }
}
