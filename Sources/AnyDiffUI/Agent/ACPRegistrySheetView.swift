import SwiftUI
import AnyDiffCore

public typealias ACPRegistryView = ACPRegistrySheetView

public struct ACPRegistrySheetView: View {
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public var theme: Theme
    public var workingDirectory: String
    public var onBack: () -> Void

    @State private var searchText: String = ""
    @State private var selectedFilter: RegistryFilter = .all
    @State private var agents: [ACPRegistryAgentEntry] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var installingAgentId: String? = nil
    @State private var installProgress: Double = 0.0
    @State private var downloadTask: Task<Void, Never>? = nil

    @FocusState private var isSearchFocused: Bool
    @State private var isSearchVisible: Bool = false
    @State private var isSearchHovered: Bool = false
    @State private var isBackHovered: Bool = false
    @State private var isRefreshHovered: Bool = false
    @State private var isBadgeHovered: Bool = false

    private enum RegistryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case installed = "Installed"

        var id: String { rawValue }
    }

    public init(
        coordinator: AgentSessionCoordinator,
        theme: Theme,
        workingDirectory: String,
        onBack: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.theme = theme
        self.workingDirectory = workingDirectory
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top navigation & title bar
            headerView
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Optional search bar (toggled via header icon, like Changes files)
            if isSearchVisible {
                searchBar
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Single crisp hairline divider
            Divider()
                .background(Color(theme.excerptHeaderBorder).opacity(0.35))

            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(theme.background))
        .task {
            await loadAgents(forceRefresh: false)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(isBackHovered ? Color(theme.foreground) : Color(theme.gutterForeground))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(theme.foreground).opacity(isBackHovered ? 0.08 : 0))
                )
            }
            .buttonStyle(.plain)
            .layoutPriority(2)
            .onHover { isBackHovered = $0 }

            Spacer(minLength: 4)

            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.accentColor)

                Text("ACP Registry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))

                if !agents.isEmpty {
                    Button(action: {
                        guard installedCount > 0 else { return }
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedFilter = (selectedFilter == .all) ? .installed : .all
                        }
                    }) {
                        Text(installedCount > 0 ? "\(installedCount)/\(agents.count)" : "\(agents.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(
                            selectedFilter == .installed
                                ? Color.accentColor
                                : (isBadgeHovered && installedCount > 0 ? Color(theme.foreground) : Color(theme.gutterForeground))
                        )
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(
                                    selectedFilter == .installed
                                        ? Color.accentColor.opacity(isBadgeHovered ? 0.22 : 0.15)
                                        : Color(theme.foreground).opacity(isBadgeHovered && installedCount > 0 ? 0.10 : 0.06)
                                )
                        )
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .disabled(installedCount == 0)
                    .help(
                        installedCount == 0
                            ? "\(agents.count) agents available"
                            : (selectedFilter == .installed
                                ? "Showing \(installedCount) installed agents. Click to show all \(agents.count)."
                                : "Showing all \(agents.count) agents (\(installedCount) installed). Click to show only installed.")
                    )
                    .onHover { isBadgeHovered = $0 }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                // Search toggle button (like in Changes files)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSearchVisible.toggle()
                        if isSearchVisible {
                            isSearchFocused = true
                        } else {
                            searchText = ""
                            isSearchFocused = false
                        }
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSearchVisible ? .accentColor : (isSearchHovered ? Color(theme.foreground) : Color(theme.gutterForeground)))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSearchVisible ? Color.accentColor.opacity(0.12) : Color(theme.foreground).opacity(isSearchHovered ? 0.08 : 0))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isSearchHovered = $0 }
                .help("Filter agents (Cmd+F)")

                Button(action: {
                    Task { await loadAgents(forceRefresh: true) }
                }) {
                    ZStack {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.68)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(isRefreshHovered ? Color(theme.foreground) : Color(theme.gutterForeground))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(theme.foreground).opacity(isRefreshHovered && !isLoading ? 0.08 : 0))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .onHover { isRefreshHovered = $0 }
                .help(isLoading ? "Fetching registry from CDN..." : "Refresh registry from CDN")
            }
            .layoutPriority(2)
        }
    }

    // MARK: - Search & Custom Modern Filter Tabs

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(theme.gutterForeground).opacity(0.8))

            TextField("Search agents by name, description, author...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundColor(Color(theme.foreground))
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(theme.gutterForeground))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(theme.foreground).opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color(theme.excerptHeaderBorder).opacity(0.35), lineWidth: 0.8)
        )
    }


    private var installedCount: Int {
        agents.filter { coordinator.isAgentInstalled(id: $0.id) }.count
    }

    // MARK: - Content View

    private var filteredAgents: [ACPRegistryAgentEntry] {
        agents.filter { agent in
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let matchesName = agent.name.lowercased().contains(query)
                let matchesDesc = agent.description.lowercased().contains(query)
                let matchesId = agent.id.lowercased().contains(query)
                let matchesAuthor = agent.authors?.joined(separator: " ").lowercased().contains(query) ?? false
                guard matchesName || matchesDesc || matchesId || matchesAuthor else { return false }
            }

            let isInstalled = coordinator.isAgentInstalled(id: agent.id)
            switch selectedFilter {
            case .all:
                return true
            case .installed:
                return isInstalled
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoading && agents.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.9)
                Text("Fetching ACP Registry...")
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.gutterForeground))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = errorMessage, agents.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                Text("Failed to load ACP Registry")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color(theme.gutterForeground))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button("Retry") {
                    Task { await loadAgents(forceRefresh: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if filteredAgents.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 24))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.6))
                Text(searchText.isEmpty ? (selectedFilter == .installed ? "No installed agents" : "No agents found") : "No agents match \"\(searchText)\"")
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.gutterForeground))

                if selectedFilter == .installed {
                    Button("Show all agents") {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedFilter = .all
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VirtualizedAgentRegistryListView(
                agents: filteredAgents,
                theme: theme,
                coordinator: coordinator,
                installingAgentId: installingAgentId,
                installProgress: installProgress,
                onInstall: { agent in
                    installAgent(agent: agent)
                },
                onStart: { agent in
                    launchAgent(agent: agent)
                },
                onRemove: { agent in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        coordinator.uninstallRegistryAgent(id: agent.id)
                    }
                },
                onCancelInstall: { agent in
                    cancelInstall(agent: agent)
                }
            )
        }
    }

    // MARK: - Actions

    private func loadAgents(forceRefresh: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await ACPRegistryService.shared.fetchAgents(forceRefresh: forceRefresh)
            await MainActor.run {
                self.agents = fetched
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func installAgent(agent: ACPRegistryAgentEntry) {
        if agent.distribution.npx != nil {
            withAnimation(.easeInOut(duration: 0.15)) {
                _ = coordinator.installRegistryAgent(agent)
            }
        } else if agent.distribution.binary != nil {
            downloadTask?.cancel()
            installingAgentId = agent.id
            installProgress = 0.0
            downloadTask = Task {
                do {
                    let binaryPath = try await ACPRegistryService.shared.downloadAndInstallBinary(for: agent) { progress in
                        Task { @MainActor in
                            self.installProgress = progress
                        }
                    }
                    await MainActor.run {
                        coordinator.installRegistryAgent(agent, binaryPath: binaryPath)
                        self.installingAgentId = nil
                        self.installProgress = 0.0
                        self.downloadTask = nil
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.installingAgentId = nil
                        self.installProgress = 0.0
                        self.downloadTask = nil
                    }
                } catch {
                    await MainActor.run {
                        self.installingAgentId = nil
                        self.installProgress = 0.0
                        self.downloadTask = nil
                        self.errorMessage = "Failed to download binary: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func cancelInstall(agent: ACPRegistryAgentEntry) {
        downloadTask?.cancel()
        downloadTask = nil
        installingAgentId = nil
        installProgress = 0.0
    }

    private func launchAgent(agent: ACPRegistryAgentEntry) {
        let preset = coordinator.allPresets.first(where: { $0.id == agent.id }) ?? agent.toAgentPreset()
        onBack()
        _ = coordinator.createNewSession(workingDirectory: workingDirectory, preset: preset)
    }
}
