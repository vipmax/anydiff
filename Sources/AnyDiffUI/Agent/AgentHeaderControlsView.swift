import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentHeaderControlsView: View {
    @ObservedObject public var agentManager: AgentSessionManager
    public let theme: Theme
    public let accentColor: Color
    public let workingDirectory: String
    public var onSend: (() -> Void)? = nil

    @State private var isModelHovered: Bool = false
    @State private var isSendHovered: Bool = false
    @State private var isStopHovered: Bool = false
    @State private var isUsageHovered: Bool = false

    public init(
        agentManager: AgentSessionManager,
        theme: Theme,
        accentColor: Color,
        workingDirectory: String,
        onSend: (() -> Void)? = nil
    ) {
        self.agentManager = agentManager
        self.theme = theme
        self.accentColor = accentColor
        self.workingDirectory = workingDirectory
        self.onSend = onSend
    }

    private var isBusy: Bool {
        agentManager.status == .busy || agentManager.status == .connecting || agentManager.initializationState == .starting
    }

    private var canSend: Bool {
        let hasDraft = !agentManager.draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !agentManager.draftAttachments.isEmpty
        return hasDraft && agentManager.canAcceptPrompt
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // Model selector / settings dropdown
            modelSelectorView

            // Context usage ring
            if let pct = agentManager.contextUsagePercentage {
                contextUsageRing(percentage: pct)
            }

            // Send / Stop button
            sendOrCancelControls
        }
    }

    @ViewBuilder
    private var modelSelectorView: some View {
        if agentManager.initializationState == .starting || agentManager.status == .connecting {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                Text(agentManager.agentTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(theme.foreground).opacity(0.75))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        } else if !agentManager.availableAgentSettings.isEmpty {
            Button(action: showAgentSettingsMenu) {
                HStack(spacing: 4) {
                    Text(agentSettingsSummary)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(isModelHovered ? 0.9 : 0.6)
                }
                .foregroundColor(isModelHovered ? Color(theme.foreground) : Color(theme.foreground).opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(minHeight: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isModelHovered ? Color(theme.foreground).opacity(0.08) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isModelHovered ? Color(theme.excerptHeaderBorder).opacity(0.5) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("Select Model & Agent Settings")
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isModelHovered = hovering
                }
            }
        }
    }

    private func contextUsageRing(percentage: Int) -> some View {
        let progress = CGFloat(max(0, min(100, percentage))) / 100

        return ZStack {
            Circle()
                .stroke(Color(nsColor: .secondaryLabelColor).opacity(0.25), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color(nsColor: .secondaryLabelColor).opacity(0.85),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .frame(width: 16, height: 16)
        .overlay(alignment: .top) {
            if isUsageHovered {
                Text("\(percentage)%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(theme.foreground))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule().stroke(Color(theme.excerptHeaderBorder).opacity(0.7), lineWidth: 1)
                    )
                    .offset(y: 18)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .help("Context usage: \(percentage)%")
        .onHover { isUsageHovered = $0 }
    }

    @ViewBuilder
    private var sendOrCancelControls: some View {
        HStack(spacing: 2) {
            if isBusy {
                Button(action: { agentManager.cancel() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isStopHovered ? Color.red : Color.red.opacity(0.85))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Stop Generation (Esc)")
                .onHover { isStopHovered = $0 }
            }

            if !isBusy {
                Button(action: handleTriggerSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(canSend ? accentColor : Color(theme.gutterForeground).opacity(0.35))
                        .frame(width: 16, height: 16)
                        .scaleEffect(isSendHovered && canSend ? 1.08 : 1.0)
                        .animation(.easeOut(duration: 0.12), value: isSendHovered)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send Message (Enter)")
                .onHover { isSendHovered = $0 }
            }
        }
    }

    private func handleTriggerSend() {
        if let onSend {
            onSend()
        } else {
            let prompt = agentManager.draftPrompt
            let images = agentManager.draftAttachments
            agentManager.draftPrompt = ""
            agentManager.draftAttachments = []
            agentManager.sendPrompt(prompt, images: images, workingDirectory: workingDirectory)
        }
    }

    private var agentSettingsSummary: String {
        var parts: [String] = []
        let model = agentManager.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty {
            parts.append(model)
        }
        let effort = agentManager.selectedReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty {
            parts.append(effort)
        }
        if parts.isEmpty {
            let mode = agentManager.selectedAgentMode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mode.isEmpty {
                parts.append(mode)
            }
        }
        if parts.isEmpty {
            for opt in agentManager.availableAgentSettings {
                if let cur = opt.currentValue, !cur.isEmpty {
                    let name = opt.options?.first(where: { $0.value == cur })?.name ?? cur
                    parts.append(name)
                    break
                }
            }
        }
        if parts.isEmpty {
            parts.append(agentManager.agentTitle)
        }
        return parts.joined(separator: " · ")
    }

    private struct OptionGroup: Identifiable {
        let id: String
        let groupName: String
        let items: [ACPConfigOption.OptionValue]
    }

    private func groupOptionsByPrefix(_ values: [ACPConfigOption.OptionValue]) -> [OptionGroup] {
        var dict: [String: [ACPConfigOption.OptionValue]] = [:]
        var order: [String] = []

        for val in values {
            let groupName: String
            if let slashIndex = val.name.firstIndex(of: "/") {
                groupName = String(val.name[..<slashIndex]).trimmingCharacters(in: .whitespaces)
            } else if let slashIndex = val.value.firstIndex(of: "/") {
                groupName = String(val.value[..<slashIndex]).capitalized
            } else {
                groupName = "General"
            }

            if dict[groupName] == nil {
                order.append(groupName)
                dict[groupName] = []
            }
            dict[groupName]?.append(val)
        }

        return order.map { OptionGroup(id: $0, groupName: $0, items: dict[$0] ?? []) }
    }

    private func showAgentSettingsMenu() {
        let menu = NSMenu(title: "Agent Settings")
        var targets: [AgentSettingsMenuActionTarget] = []

        func makeValueItem(option: ACPConfigOption, value: ACPConfigOption.OptionValue) -> NSMenuItem {
            let target = AgentSettingsMenuActionTarget { [weak agentManager] in
                agentManager?.selectConfigOption(id: option.id, value: value.value)
            }
            targets.append(target)
            let item = NSMenuItem(
                title: value.name,
                action: #selector(AgentSettingsMenuActionTarget.invoke(_:)),
                keyEquivalent: ""
            )
            item.target = target
            item.state = isOptionSelected(option: option, value: value) ? .on : .off
            return item
        }

        for option in agentManager.availableAgentSettings {
            if let values = option.options, !values.isEmpty {
                let currentText = settingsValue(for: option)
                let parentTitle = currentText.isEmpty
                    ? option.name
                    : "\(option.name) — \(currentText)"
                let parentItem = NSMenuItem(title: parentTitle, action: nil, keyEquivalent: "")
                let subMenu = NSMenu(title: option.name)

                if values.count > 20 {
                    let groups = groupOptionsByPrefix(values)
                    if groups.count > 1 {
                        for group in groups {
                            let groupItem = NSMenuItem(title: group.groupName, action: nil, keyEquivalent: "")
                            let groupMenu = NSMenu(title: group.groupName)
                            for value in group.items {
                                groupMenu.addItem(makeValueItem(option: option, value: value))
                            }
                            groupItem.submenu = groupMenu
                            subMenu.addItem(groupItem)
                        }
                    } else {
                        for value in values {
                            subMenu.addItem(makeValueItem(option: option, value: value))
                        }
                    }
                } else {
                    for value in values {
                        subMenu.addItem(makeValueItem(option: option, value: value))
                    }
                }

                parentItem.submenu = subMenu
                menu.addItem(parentItem)
            } else if option.isBoolean {
                let nextValue = option.boolValue ? "false" : "true"
                let target = AgentSettingsMenuActionTarget { [weak agentManager] in
                    agentManager?.selectConfigOption(id: option.id, value: nextValue)
                }
                targets.append(target)
                let item = NSMenuItem(
                    title: option.name,
                    action: #selector(AgentSettingsMenuActionTarget.invoke(_:)),
                    keyEquivalent: ""
                )
                item.target = target
                item.state = option.boolValue ? .on : .off
                menu.addItem(item)
            }
        }

        withExtendedLifetime(targets) {
            _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private func isOptionSelected(option: ACPConfigOption, value: ACPConfigOption.OptionValue) -> Bool {
        if let cur = option.currentValue, !cur.isEmpty {
            if cur == value.value || cur == value.name {
                return true
            }
        }
        switch option.id {
        case ACPConfigOptionID.model:
            return agentManager.selectedModelValue == value.value || agentManager.selectedModel == value.name
        case ACPConfigOptionID.reasoningEffort:
            return agentManager.selectedReasoningEffortValue == value.value || agentManager.selectedReasoningEffort == value.name
        case ACPConfigOptionID.mode:
            return agentManager.selectedAgentModeValue == value.value || agentManager.selectedAgentMode == value.name
        default:
            return false
        }
    }

    private func settingsValue(for option: ACPConfigOption) -> String {
        if let current = option.currentValue,
           let selected = option.options?.first(where: { $0.value == current }) {
            return selected.name
        }
        if option.isBoolean {
            return option.boolValue ? "On" : "Off"
        }
        return option.currentValue ?? "—"
    }
}

private final class AgentSettingsMenuActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke(_ sender: NSMenuItem) {
        action()
    }
}

