import SwiftUI
import Combine
import AnyDiffCore

public struct LSPStatusPopoverView: View {
    public let theme: Theme
    public let workingDirectory: String?

    @State private var activeServers: [LSPServerStatusItem] = []
    @State private var packages: [LSPRegistryPackage] = LSPRegistryService.loadCachedPackagesFromDisk().filter(\.isLSP)
    @State private var installedPackageIds: Set<String> = []
    @State private var availablePackageIds: Set<String> = []
    @State private var installingPackageIds: Set<String> = []
    @State private var installProgress: [String: Double] = [:]
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isAutoStopEnabled: Bool = true
    @State private var idleTimeoutSeconds: TimeInterval = 300
    @State private var now: Date = Date()

    private let countdownTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init(
        theme: Theme,
        workingDirectory: String? = nil
    ) {
        self.theme = theme
        self.workingDirectory = workingDirectory
    }

    private var secondaryTextColor: Color {
        Color(theme.foreground).opacity(0.68)
    }

    private var tertiaryTextColor: Color {
        Color(theme.foreground).opacity(0.52)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                headerView

                Divider()
                    .background(Color(theme.excerptHeaderBorder).opacity(0.3))

                if let error = errorMessage {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9.5))
                        Text(error)
                            .font(.system(size: 10))
                            .lineLimit(2)
                        Spacer()
                        Button(action: { errorMessage = nil }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(5)
                }

                if isSearchVisible {
                    searchBar
                }
            }
            .padding(.horizontal, 12)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    runningSection

                    if !runningPackages.isEmpty && !otherPackages.isEmpty {
                        Divider()
                            .background(Color(theme.excerptHeaderBorder).opacity(0.3))
                    }

                    languagesSection
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 416)
        .frame(minHeight: 460, maxHeight: 520)
        .onAppear {
            now = Date()
            loadStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: LSPWorkspaceService.serversDidChangeNotification)) { _ in
            now = Date()
            loadStatuses()
        }
        .onReceive(countdownTimer) { tick in
            now = tick
            if !activeServers.isEmpty {
                refreshActiveStatuses()
            }
        }
    }

    // MARK: - Header & Search

    private var autoStopShortLabel: String {
        guard isAutoStopEnabled, idleTimeoutSeconds > 0 else { return "Off" }
        let mins = Int(round(idleTimeoutSeconds / 60.0))
        if mins > 0 {
            return "\(mins)m"
        }
        return "\(Int(idleTimeoutSeconds))s"
    }

    private var runningServersSubtitle: String {
        guard !activeServers.isEmpty else { return "No active servers" }
        let word = activeServers.count == 1 ? "server" : "servers"
        return "\(activeServers.count) \(word) running"
    }

    private func toggleSearchBar() {
        isSearchVisible.toggle()
        if isSearchVisible {
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        } else {
            searchText = ""
            isSearchFieldFocused = false
        }
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(activeServers.isEmpty ? secondaryTextColor : Color.green)

            VStack(alignment: .leading, spacing: 1) {
                Text("Language Servers (LSP)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))

                Text(runningServersSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(secondaryTextColor)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            }

            HStack(spacing: 5) {
                Button(action: toggleAutoStop) {
                    HStack(spacing: 3.5) {
                        Image(systemName: "timer")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(autoStopShortLabel)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(isAutoStopEnabled ? Color(theme.accentColor) : tertiaryTextColor)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isAutoStopEnabled ? Color(theme.accentColor).opacity(0.12) : Color(theme.foreground).opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isAutoStopEnabled ? Color(theme.accentColor).opacity(0.35) : Color(theme.excerptHeaderBorder).opacity(0.35), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Auto-Stop After 1m") { setIdleTimeoutPreset(60) }
                    Button("Auto-Stop After 5m") { setIdleTimeoutPreset(300) }
                    Button("Auto-Stop After 15m") { setIdleTimeoutPreset(900) }
                    Divider()
                    Button("Disable Auto-Stop") { setIdleTimeoutPreset(0) }
                }
                .help(isAutoStopEnabled
                    ? "Auto-stop after \(autoStopShortLabel) of inactivity. Click to disable, right-click for presets."
                    : "Auto-stop disabled. Click to enable, right-click for presets.")

                Button(action: toggleSearchBar) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(isSearchVisible ? Color(theme.accentColor) : secondaryTextColor)
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSearchVisible ? Color(theme.accentColor).opacity(0.12) : Color(theme.foreground).opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(isSearchVisible ? Color(theme.accentColor).opacity(0.35) : Color(theme.excerptHeaderBorder).opacity(0.35), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(isSearchVisible ? "Hide search" : "Search languages")
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(secondaryTextColor)

            TextField("Search languages (Rust, Python, Swift...)", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color(theme.foreground))
                .focused($isSearchFieldFocused)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(secondaryTextColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(theme.foreground).opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(theme.excerptHeaderBorder).opacity(0.4), lineWidth: 0.5)
        )
    }

    // MARK: - Language Filtering & Grouping

    private func languageDisplayName(for package: LSPRegistryPackage) -> String {
        languageName(package.language)
    }

    private func languageName(_ id: String) -> String {
        switch id.lowercased() {
        case "csharp", "cs": return "C#"
        case "rust": return "Rust"
        case "python": return "Python"
        case "typescript": return "TypeScript / React"
        case "javascript": return "JavaScript"
        case "swift": return "Swift"
        case "go": return "Go"
        case "c": return "C"
        case "cpp": return "C++"
        case "java": return "Java"
        case "kotlin": return "Kotlin"
        case "php": return "PHP"
        case "ruby": return "Ruby"
        case "dart": return "Dart"
        case "elixir": return "Elixir"
        case "scala": return "Scala"
        case "vue": return "Vue"
        case "svelte": return "Svelte"
        case "astro": return "Astro"
        case "graphql": return "GraphQL"
        case "prisma": return "Prisma"
        case "dockerfile": return "Dockerfile"
        case "terraform": return "Terraform"
        case "sql": return "SQL"
        case "html": return "HTML"
        case "css": return "CSS"
        case "json": return "JSON"
        case "markdown": return "Markdown"
        case "yaml": return "YAML"
        case "bash", "sh": return "Bash"
        case "lua": return "Lua"
        case "zig": return "Zig"
        case "toml": return "TOML"
        default: return id.capitalized
        }
    }

    private func activeStatusItem(for package: LSPRegistryPackage) -> LSPServerStatusItem? {
        let pkgLang = package.language.lowercased()
        guard let item = activeServers.first(where: { $0.languageId.lowercased() == pkgLang }) else {
            return nil
        }
        let sameLanguageCount = packages.filter { $0.language.lowercased() == pkgLang }.count
        guard sameLanguageCount > 1 else {
            return item
        }
        let serverName = item.serverName.lowercased()
        if serverName == package.binary.lowercased() ||
           serverName == package.id.lowercased() ||
           serverName == package.name.lowercased() {
            return item
        }
        return nil
    }

    private func matchesSearch(_ pkg: LSPRegistryPackage) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return true }
        let title = languageDisplayName(for: pkg).lowercased()
        return title.contains(query)
            || pkg.name.lowercased().contains(query)
            || pkg.binary.lowercased().contains(query)
            || pkg.language.lowercased().contains(query)
            || pkg.fileExtensions.contains(where: { $0.lowercased().contains(query) })
            || (pkg.summary?.lowercased().contains(query) ?? false)
    }

    private var runningPackages: [LSPRegistryPackage] {
        packages.filter { pkg in
            activeStatusItem(for: pkg) != nil && matchesSearch(pkg)
        }
    }

    private var otherPackages: [LSPRegistryPackage] {
        packages.filter { pkg in
            activeStatusItem(for: pkg) == nil && matchesSearch(pkg)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var runningSection: some View {
        if !runningPackages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("RUNNING")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(secondaryTextColor)
                    Spacer()
                    Text("\(runningPackages.count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }

                ForEach(runningPackages) { pkg in
                    runningRow(for: pkg)
                }
            }
        }
    }

    private func runningRow(for pkg: LSPRegistryPackage) -> some View {
        let activeItem = activeStatusItem(for: pkg)
        let state = activeItem?.state ?? .ready
        let docCount = activeItem?.openDocumentsCount ?? 0
        let langTitle = languageDisplayName(for: pkg)
        let countdownText = remainingTimeText(for: activeItem)
        let docsLabel = docCount > 0 ? " • \(docCount) \(docCount == 1 ? "doc" : "docs")" : ""

        return HStack(spacing: 8) {
            Circle()
                .fill(statusColor(for: state))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    Text(langTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))

                    Text("(\(pkg.binary))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }

                HStack(spacing: 0) {
                    Text("\(statusDescription(for: state))\(docsLabel)")
                        .font(.system(size: 9.5))
                        .foregroundColor(secondaryTextColor)

                    if let countdownText {
                        Text(" • ")
                            .font(.system(size: 9.5))
                            .foregroundColor(tertiaryTextColor)
                        Text(countdownText)
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundColor(tertiaryTextColor)
                            .help("Idle auto-stop countdown")
                    }
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: { restart(package: pkg) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(secondaryTextColor)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(theme.foreground).opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .help("Restart \(langTitle)")

                Button(action: { stop(package: pkg) }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(Color.red.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.red.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .help("Stop \(langTitle)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(theme.foreground).opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(theme.excerptHeaderBorder).opacity(0.25), lineWidth: 0.5)
        )
        .contextMenu {
            Button(action: { restart(package: pkg) }) {
                Label("Restart \(langTitle)", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive, action: { stop(package: pkg) }) {
                Label("Stop \(langTitle)", systemImage: "stop.fill")
            }
            if installedPackageIds.contains(pkg.id) {
                Divider()
                Button(role: .destructive, action: { uninstall(package: pkg) }) {
                    Label("Uninstall Local \(pkg.name)", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(runningPackages.isEmpty ? "LANGUAGES" : "OTHER LANGUAGES")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(secondaryTextColor)

                Spacer()

                Text("\(otherPackages.count) servers")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }

            LazyVStack(spacing: 4) {
                ForEach(otherPackages) { pkg in
                    languageRow(for: pkg)
                }
            }
        }
    }

    private func languageRow(for pkg: LSPRegistryPackage) -> some View {
        let isLocallyInstalled = installedPackageIds.contains(pkg.id)
        let isAvailable = isLocallyInstalled || availablePackageIds.contains(pkg.id)
        let isInstalling = installingPackageIds.contains(pkg.id)
        let progress = installProgress[pkg.id] ?? 0.0
        let langTitle = languageDisplayName(for: pkg)

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(langTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))

                    Text("(\(pkg.binary))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(secondaryTextColor)
                }

                if isAvailable {
                    Text(pkg.download?.type == .systemOnly ? "System toolchain" : "Installed locally")
                        .font(.system(size: 9.5))
                        .foregroundColor(Color.green.opacity(0.85))
                } else if let summary = pkg.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 9.5))
                        .foregroundColor(secondaryTextColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if isInstalling {
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .stroke(Color(theme.accentColor).opacity(0.25), lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: max(0.1, CGFloat(progress)))
                            .stroke(
                                Color(theme.accentColor),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 9, height: 9)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(Color(theme.accentColor))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(theme.accentColor).opacity(0.12))
                )
            } else if isAvailable {
                Button(action: { start(package: pkg) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 7.5))
                        Text("Start")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(Color(theme.accentColor))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(theme.accentColor).opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .help("Start \(langTitle)")
            } else {
                if let download = pkg.download, download.type == .systemOnly {
                    Text(download.systemRequirementLabel)
                        .font(.system(size: 9.5))
                        .foregroundColor(tertiaryTextColor)
                        .help(download.instructions ?? download.systemRequirementLabel)
                } else {
                    Button(action: { install(package: pkg) }) {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 9))
                            Text("Install")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(Color(theme.accentColor))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(theme.accentColor).opacity(0.12))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .contextMenu {
            if isAvailable {
                Button(action: { start(package: pkg) }) {
                    Label("Start \(langTitle)", systemImage: "play.fill")
                }
            } else if pkg.download?.type != .systemOnly {
                Button(action: { install(package: pkg) }) {
                    Label("Install \(pkg.name)", systemImage: "arrow.down.circle")
                }
            }

            if isLocallyInstalled {
                Divider()
                Button(role: .destructive, action: { uninstall(package: pkg) }) {
                    Label("Uninstall Local \(pkg.name)", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Actions & Helpers

    private func statusColor(for state: LSPClient.State) -> Color {
        switch state {
        case .ready: return .green
        case .initializing: return .orange
        case .unstarted, .stopped: return .gray
        }
    }

    private func statusDescription(for state: LSPClient.State) -> String {
        switch state {
        case .ready: return "Ready"
        case .initializing: return "Initializing"
        case .unstarted: return "Unstarted"
        case .stopped: return "Stopped"
        }
    }

    private func remainingTimeText(for item: LSPServerStatusItem?) -> String? {
        guard isAutoStopEnabled, let deadline = item?.autoStopDeadline else { return nil }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func setIdleTimeoutPreset(_ seconds: TimeInterval) {
        if seconds <= 0 {
            isAutoStopEnabled = false
        } else {
            isAutoStopEnabled = true
            idleTimeoutSeconds = seconds
        }
        Task { @MainActor in
            await LSPWorkspaceService.shared.setIdleTimeout(seconds, persist: true)
            now = Date()
            refreshActiveStatuses()
        }
    }

    private func toggleAutoStop() {
        let newValue = !isAutoStopEnabled
        isAutoStopEnabled = newValue
        Task { @MainActor in
            await LSPWorkspaceService.shared.setAutoStopEnabled(newValue)
            now = Date()
            refreshActiveStatuses()
        }
    }

    private func refreshActiveStatuses() {
        Task { @MainActor in
            let autoStop = await LSPWorkspaceService.shared.isAutoStopEnabled
            let timeout = await LSPWorkspaceService.shared.idleTimeout
            let statuses = await LSPWorkspaceService.shared.activeServerStatuses()
            self.isAutoStopEnabled = autoStop
            if timeout > 0 {
                self.idleTimeoutSeconds = timeout
            }
            self.activeServers = statuses
        }
    }

    private func loadStatuses() {
        Task { @MainActor in
            isLoading = true
            let autoStop = await LSPWorkspaceService.shared.isAutoStopEnabled
            let timeout = await LSPWorkspaceService.shared.idleTimeout
            let statuses = await LSPWorkspaceService.shared.activeServerStatuses()
            self.isAutoStopEnabled = autoStop
            if timeout > 0 {
                self.idleTimeoutSeconds = timeout
            }
            self.activeServers = statuses

            let allPkgs = await LSPRegistryService.shared.cachedPackages()
            var installed: Set<String> = []
            var available: Set<String> = []

            for pkg in allPkgs {
                if LSPRegistryService.shared.isInstalled(package: pkg) {
                    installed.insert(pkg.id)
                    available.insert(pkg.id)
                } else if await LSPWorkspaceService.shared.isPackageAvailable(pkg) {
                    available.insert(pkg.id)
                }
            }

            self.packages = allPkgs
            self.installedPackageIds = installed
            self.availablePackageIds = available
            self.isLoading = false
        }
    }

    private func install(package: LSPRegistryPackage) {
        guard !installingPackageIds.contains(package.id) else { return }
        installingPackageIds.insert(package.id)
        installProgress[package.id] = 0.0
        errorMessage = nil

        Task {
            do {
                _ = try await LSPRegistryService.shared.downloadAndInstall(package: package) { progress in
                    Task { @MainActor in
                        self.installProgress[package.id] = progress
                    }
                }
                await MainActor.run {
                    self.installedPackageIds.insert(package.id)
                    self.availablePackageIds.insert(package.id)
                    self.installingPackageIds.remove(package.id)
                    self.installProgress.removeValue(forKey: package.id)
                    SoundFeedback.play(.completion)
                    loadStatuses()
                }
            } catch {
                await MainActor.run {
                    self.installingPackageIds.remove(package.id)
                    self.installProgress.removeValue(forKey: package.id)
                    let title = languageDisplayName(for: package)
                    self.errorMessage = "\(title): \(error.localizedDescription)"
                    SoundFeedback.play(.error)
                }
            }
        }
    }

    private func uninstall(package: LSPRegistryPackage) {
        LSPRegistryService.shared.uninstall(package: package)
        installedPackageIds.remove(package.id)
        loadStatuses()
    }

    private func start(package: LSPRegistryPackage) {
        let root = workingDirectory ?? FileManager.default.currentDirectoryPath
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            do {
                _ = try await LSPWorkspaceService.shared.startPackage(package, rootPath: root)
                loadStatuses()
            } catch {
                let title = languageDisplayName(for: package)
                self.errorMessage = "Failed to start \(title): \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private func restart(package: LSPRegistryPackage) {
        let root = workingDirectory ?? FileManager.default.currentDirectoryPath
        Task { @MainActor in
            isLoading = true
            errorMessage = nil
            do {
                _ = try await LSPWorkspaceService.shared.restartPackage(package, rootPath: root)
                loadStatuses()
            } catch {
                let title = languageDisplayName(for: package)
                self.errorMessage = "Failed to restart \(title): \(error.localizedDescription)"
                self.isLoading = false
            }
        }
    }

    private func stop(package: LSPRegistryPackage) {
        Task { @MainActor in
            await LSPWorkspaceService.shared.stopPackage(package)
            loadStatuses()
        }
    }
}
