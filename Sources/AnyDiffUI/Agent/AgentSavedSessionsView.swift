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
    @State private var errorMessage: String? = nil
    @State private var searchQuery: String = ""
    @State private var loadingSessionId: String? = nil
    @State private var isBackHovered: Bool = false
    @State private var isStartNewHovered: Bool = false

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
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .background(Color(theme.excerptHeaderBorder).opacity(0.6))

            // Search / Filter Bar
            searchAndControlBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

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
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("Agents")
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(Color(theme.foreground))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(theme.foreground).opacity(isBackHovered ? 0.09 : 0))
                )
            }
            .buttonStyle(.plain)
            .onHover { isBackHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isBackHovered)

            // Agent Badge & Name
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(presetColor.opacity(0.18))
                        .frame(width: 22, height: 22)
                    AgentIconView(icon: preset.iconName, tintColor: presetColor, size: 12)
                }

                Text("\(preset.name) Sessions")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(theme.foreground))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }

            Spacer()

            // Start New Session Button
            Button(action: onStartNew) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Start New")
                        .font(.system(size: 11.5, weight: .semibold))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundColor(presetColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(presetColor.opacity(isStartNewHovered ? 0.14 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(presetColor.opacity(isStartNewHovered ? 0.4 : 0), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { isStartNewHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isStartNewHovered)
        }
    }

    // MARK: - Search & Controls

    private var searchAndControlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(theme.gutterForeground))

                TextField("Filter sessions by title or ID...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(theme.foreground))

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

            Button(action: { loadSessions() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(theme.gutterForeground))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(theme.foreground).opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(theme.excerptHeaderBorder).opacity(0.6), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Refresh saved sessions")
        }
    }

    // MARK: - Virtualized Session List

    private var virtualizedSessionList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(filteredSessions) { item in
                    SavedSessionCardRow(
                        item: item,
                        preset: preset,
                        presetColor: presetColor,
                        theme: theme,
                        isLoading: loadingSessionId == item.sessionId,
                        onSelect: {
                            resumeSession(item)
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
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
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let list = try await coordinator.fetchSavedSessions(for: preset, workingDirectory: workingDirectory)
                await MainActor.run {
                    self.sessions = list
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
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

// MARK: - Saved Session Card Row

private struct SavedSessionCardRow: View {
    let item: ACPSavedSessionItem
    let preset: AgentPreset
    let presetColor: Color
    let theme: Theme
    let isLoading: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    private var shortSessionId: String {
        item.shortId
    }

    private var isGenericSessionTitle: Bool {
        let t = item.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let idLower = item.sessionId.lowercased()
        let shortId = item.shortId.lowercased()
        return t == "session \(shortId)" || t == "session \(idLower)" || t == shortId || t == idLower || (t.hasPrefix("session ") && t.count <= 18)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Status / Agent Icon indicator
                ZStack {
                    Circle()
                        .fill(presetColor.opacity(isHovered ? 0.25 : 0.14))
                        .frame(width: 32, height: 32)
                    Circle()
                        .stroke(presetColor.opacity(isHovered ? 0.6 : 0.25), lineWidth: 1)
                        .frame(width: 32, height: 32)

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(presetColor)
                    }
                }
                .fixedSize()

                // Info: Title, ID & Date
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.displayTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(theme.foreground))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        if !isGenericSessionTitle {
                            Text(shortSessionId)
                                .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                                .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color(theme.foreground).opacity(0.05))
                                )
                        }
                    }

                    HStack(spacing: 8) {
                        if !item.formattedDate.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "calendar")
                                    .font(.system(size: 9))
                                Text(item.formattedDate)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundColor(Color(theme.gutterForeground))
                        }

                        if let cwd = item.cwd, !cwd.isEmpty {
                            let lastComponent = (cwd as NSString).lastPathComponent
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.system(size: 9))
                                Text(lastComponent)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .foregroundColor(Color(theme.gutterForeground).opacity(0.7))
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 0)

                // The whole card is the resume action. Keep only a compact
                // affordance so the session title and metadata get the space.
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(presetColor.opacity(isHovered ? 1.0 : 0.7))
                    .frame(width: 14, height: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(theme.foreground).opacity(isHovered ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isHovered ? presetColor.opacity(0.4) : Color(theme.excerptHeaderBorder).opacity(0.55),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(item.displayTitle)")
        .accessibilityHint("Opens this saved session")
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
