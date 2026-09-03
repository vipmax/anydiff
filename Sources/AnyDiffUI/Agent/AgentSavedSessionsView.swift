import SwiftUI
import AppKit
import AnyDiffCore

public struct AgentSavedSessionsView: View {
    public let preset: AgentPreset
    @ObservedObject public var coordinator: AgentSessionCoordinator
    public let workingDirectory: String
    public let theme: Theme
    public let onBack: () -> Void
    public let onStartNew: () -> Void

    @State private var sessions: [ACPSavedSessionItem] = []
    @State private var isLoading: Bool = true
    @State private var isStreamingMore: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isSearchVisible: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFocused: Bool
    @State private var loadingSessionId: String? = nil
    @State private var isBackHovered: Bool = false
    @State private var isStartNewHovered: Bool = false
    @State private var isSearchBtnHovered: Bool = false
    @State private var isRefreshBtnHovered: Bool = false
    @State private var loadTask: Task<Void, Never>? = nil

    public init(
        preset: AgentPreset,
        coordinator: AgentSessionCoordinator,
        workingDirectory: String,
        theme: Theme,
        onBack: @escaping () -> Void,
        onStartNew: @escaping () -> Void
    ) {
        self.preset = preset
        self.coordinator = coordinator
        self.workingDirectory = workingDirectory
        self.theme = theme
        self.onBack = onBack
        self.onStartNew = onStartNew
    }

    private var presetColor: Color {
        preset.color
    }

    private var filteredSessions: [ACPSavedSessionItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return sessions
        }
        return sessions.filter {
            $0.displayTitle.lowercased().contains(query) ||
            $0.sessionId.lowercased().contains(query) ||
            ($0.updatedAt?.lowercased().contains(query) ?? false)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .background(Color(theme.excerptHeaderBorder).opacity(0.6))

            // Search / Filter Bar (Collapsible)
            if isSearchVisible {
                searchBarView
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))

                Divider()
                    .background(Color(theme.excerptHeaderBorder).opacity(0.4))
            }

            // Content Area
            ZStack {
                Color(theme.background)

                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(error)
                } else if sessions.isEmpty {
                    emptyView
                } else if filteredSessions.isEmpty {
                    noSearchResultsView
                } else {
                    virtualizedSessionList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(theme.background))
        .onAppear {
            loadSessions()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
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

            // Agent Badge & Name
            HStack(spacing: 7) {
                AgentIconView(icon: preset.iconName, tintColor: presetColor, size: 16)
                    .fixedSize()

                ViewThatFits(in: .horizontal) {
                    Text("\(preset.name) Sessions")
                        .lineLimit(1)
                    Text(preset.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(theme.foreground))

                if !sessions.isEmpty {
                    HStack(spacing: 4) {
                        Text("\(sessions.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(theme.gutterForeground))
                            .lineLimit(1)

                        if isStreamingMore {
                            ProgressView()
                                .scaleEffect(0.45)
                                .frame(width: 10, height: 10)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(theme.foreground).opacity(0.06))
                    )
                    .fixedSize()
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            // Action Buttons: [+] [🔍] [↻]
            HStack(spacing: 6) {
                // 1. Start New Session (+)
                Button(action: onStartNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isStartNewHovered ? Color(theme.foreground) : Color(theme.gutterForeground))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(theme.foreground).opacity(isStartNewHovered ? 0.08 : 0))
                        )
                }
                .buttonStyle(.plain)
                .help("Start New Session")
                .onHover { isStartNewHovered = $0 }

                // 2. Search Icon Button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSearchVisible.toggle()
                        if isSearchVisible {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                isSearchFocused = true
                            }
                        } else {
                            searchQuery = ""
                            isSearchFocused = false
                        }
                    }
                }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSearchVisible ? presetColor : (isSearchBtnHovered ? Color(theme.foreground) : Color(theme.gutterForeground)))
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSearchVisible ? presetColor.opacity(0.12) : Color(theme.foreground).opacity(isSearchBtnHovered ? 0.08 : 0))
                        )
                }
                .buttonStyle(.plain)
                .help(isSearchVisible ? "Hide search" : "Search sessions")
                .onHover { isSearchBtnHovered = $0 }

                // 3. Refresh Icon Button
                Button(action: { loadSessions() }) {
                    ZStack {
                        if isLoading && sessions.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.68)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(isRefreshBtnHovered ? Color(theme.foreground) : Color(theme.gutterForeground))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(theme.foreground).opacity(isRefreshBtnHovered && !isLoading ? 0.08 : 0))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .help(isLoading ? "Fetching saved sessions..." : "Refresh saved sessions")
                .onHover { isRefreshBtnHovered = $0 }
            }
            .layoutPriority(2)
        }
    }

    // MARK: - Collapsible Search Bar

    private var searchBarView: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(Color(theme.gutterForeground))

            TextField("Filter sessions by title or ID...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundColor(Color(theme.foreground))
                .focused($isSearchFocused)

            if !searchQuery.isEmpty {
                Button(action: { searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Color(theme.gutterForeground))
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
                .stroke(Color(theme.excerptHeaderBorder).opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Virtualized Session List

    private var virtualizedSessionList: some View {
        VirtualizedSavedSessionsListView(
            sessions: filteredSessions,
            preset: preset,
            theme: theme,
            loadingSessionId: loadingSessionId,
            onSelect: { item in
                resumeSession(item)
            }
        )
        .padding(.vertical, 8)
    }

    // MARK: - Loading & Error States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.9)

            Text("Querying agent for saved sessions...")
                .font(.system(size: 12))
                .foregroundColor(Color(theme.gutterForeground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundColor(.orange)

            Text("Unable to load sessions")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(theme.foreground))

            Text(error)
                .font(.system(size: 11))
                .foregroundColor(Color(theme.gutterForeground))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: { loadSessions() }) {
                Text("Retry")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(presetColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(presetColor.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28))
                .foregroundColor(Color(theme.gutterForeground).opacity(0.6))

            Text("No saved sessions found")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(theme.foreground))

            Text("No past ACP sessions were found in this directory for \(preset.name).")
                .font(.system(size: 11))
                .foregroundColor(Color(theme.gutterForeground))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text(displayWorkingDirectory)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(theme.gutterForeground).opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 360)
                .padding(.horizontal, 20)

            Button(action: onStartNew) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Start First Session")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSearchResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundColor(Color(theme.gutterForeground).opacity(0.6))

            Text("No sessions matching \"\(searchQuery)\"")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(theme.gutterForeground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadSessions() {
        loadTask?.cancel()
        isLoading = true
        isStreamingMore = false
        errorMessage = nil
        sessions = []

        loadTask = Task { @MainActor in
            do {
                var receivedAny = false
                let list = try await coordinator.fetchSavedSessions(
                    for: preset,
                    workingDirectory: workingDirectory
                ) { newBatch in
                    guard !Task.isCancelled else { return }
                    self.sessions.append(contentsOf: newBatch)
                    self.isLoading = false
                    self.isStreamingMore = true
                    receivedAny = true
                }
                guard !Task.isCancelled else { return }
                if !receivedAny {
                    self.sessions = list
                }
                self.isLoading = false
                self.isStreamingMore = false
            } catch {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                self.isStreamingMore = false
            }
        }
    }

    private func resumeSession(_ item: ACPSavedSessionItem) {
        loadingSessionId = item.sessionId
        withAnimation(.easeInOut(duration: 0.18)) {
            _ = coordinator.resumeSavedSession(savedSession: item, preset: preset, workingDirectory: workingDirectory)
        }
    }

    private var displayWorkingDirectory: String {
        let path = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home {
            return "~/"
        }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

