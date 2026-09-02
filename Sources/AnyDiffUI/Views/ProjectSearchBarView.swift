import SwiftUI
import AnyDiffCore

public struct ProjectSearchBarView: View {
    @Binding public var query: ProjectSearchQuery
    public var totalMatchesCount: Int
    public var activeMatchIndex: Int?
    public var isSearching: Bool
    public var isTruncated: Bool
    public var hasExecutedSearch: Bool
    public var theme: Theme
    public var onSearch: () -> Void
    public var onQueryChanged: () -> Void
    public var onNextMatch: () -> Void
    public var onPrevMatch: () -> Void
    public var onClose: () -> Void

    public var focusToken: UInt64 = 0

    @State private var isFieldFocused: Bool = true
    @State private var showFilters: Bool = false
    @State private var lastSubmittedQuery: ProjectSearchQuery? = nil

    public init(
        query: Binding<ProjectSearchQuery>,
        totalMatchesCount: Int,
        activeMatchIndex: Int?,
        isSearching: Bool,
        isTruncated: Bool = false,
        hasExecutedSearch: Bool = false,
        theme: Theme,
        focusToken: UInt64 = 0,
        onSearch: @escaping () -> Void = {},
        onQueryChanged: @escaping () -> Void,
        onNextMatch: @escaping () -> Void,
        onPrevMatch: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self._query = query
        self.totalMatchesCount = totalMatchesCount
        self.activeMatchIndex = activeMatchIndex
        self.isSearching = isSearching
        self.isTruncated = isTruncated
        self.hasExecutedSearch = hasExecutedSearch
        self.theme = theme
        self.focusToken = focusToken
        self.onSearch = onSearch
        self.onQueryChanged = onQueryChanged
        self.onNextMatch = onNextMatch
        self.onPrevMatch = onPrevMatch
        self.onClose = onClose
    }

    private var matchCounterText: String {
        if totalMatchesCount == 0 {
            return (hasExecutedSearch && !query.isEmpty) ? "0/0" : ""
        }
        let current = (activeMatchIndex ?? 0) + 1
        let suffix = isTruncated ? "+" : ""
        return "\(current)/\(totalMatchesCount)\(suffix)"
    }

    public var body: some View {
        VStack(spacing: 6) {
            mainSearchRow
            if showFilters {
                filtersRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Color(theme.gutterBackground)
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    @ViewBuilder
    private var mainSearchRow: some View {
        HStack(spacing: 8) {
            // Main Input Field Container
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(theme.gutterForeground))

                SearchTextFieldRepresentable(
                    text: $query.query,
                    placeholder: "Find in project...",
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    textColor: theme.foreground,
                    placeholderColor: theme.gutterForeground.withAlphaComponent(0.65),
                    focusToken: focusToken,
                    isFocused: $isFieldFocused,
                    onSubmit: {
                        let trimmed = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }

                        if lastSubmittedQuery == query && totalMatchesCount > 0 {
                            onNextMatch()
                        } else {
                            lastSubmittedQuery = query
                            onSearch()
                        }
                    },
                    onShiftSubmit: {
                        let trimmed = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }

                        if lastSubmittedQuery == query && totalMatchesCount > 0 {
                            onPrevMatch()
                        } else {
                            lastSubmittedQuery = query
                            onSearch()
                        }
                    },
                    onCancel: {
                        onClose()
                    }
                )
                .frame(height: 20)
                .onChange(of: query.query) { newText in
                    if newText.isEmpty {
                        lastSubmittedQuery = nil
                        onQueryChanged()
                    }
                }

                if !query.query.isEmpty {
                    Button(action: {
                        query.query = ""
                        lastSubmittedQuery = nil
                        onQueryChanged()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(theme.gutterForeground))
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search (Esc)")
                }

                Divider()
                    .frame(height: 14)
                    .opacity(0.3)

                // Option Toggles (Aa, wd, .*)
                HStack(spacing: 2) {
                    toggleButton(title: "Aa", isActive: query.isCaseSensitive, help: "Match Case (Alt+Cmd+C)") {
                        query.isCaseSensitive.toggle()
                        if lastSubmittedQuery != nil {
                            lastSubmittedQuery = query
                            onSearch()
                        }
                    }

                    toggleButton(title: "wd", isActive: query.isWholeWord, help: "Match Whole Word (Alt+Cmd+W)") {
                        query.isWholeWord.toggle()
                        if lastSubmittedQuery != nil {
                            lastSubmittedQuery = query
                            onSearch()
                        }
                    }

                    toggleButton(title: ".*", isActive: query.isRegex, help: "Use Regular Expression (Alt+Cmd+R)") {
                        query.isRegex.toggle()
                        if lastSubmittedQuery != nil {
                            lastSubmittedQuery = query
                            onSearch()
                        }
                    }

                    toggleButton(
                        icon: "line.3.horizontal.decrease.circle",
                        isActive: showFilters,
                        help: "Toggle Include/Exclude Filters"
                    ) {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            showFilters.toggle()
                        }
                    }
                }

                Divider()
                    .frame(height: 14)
                    .opacity(0.3)

                // Match Counter Badge or Spinner
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                        .padding(.horizontal, 4)
                } else if !matchCounterText.isEmpty {
                    Text(matchCounterText)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundColor(totalMatchesCount > 0 ? Color(theme.foreground).opacity(0.85) : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }

                // Match Navigation (< and >)
                HStack(spacing: 2) {
                    Button(action: onPrevMatch) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .foregroundColor(totalMatchesCount > 0 ? Color(theme.foreground) : Color(theme.gutterForeground).opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(totalMatchesCount == 0)
                    .help("Previous Match (Shift+Enter / Cmd+Shift+G)")

                    Button(action: onNextMatch) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 20, height: 20)
                            .foregroundColor(totalMatchesCount > 0 ? Color(theme.foreground) : Color(theme.gutterForeground).opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(totalMatchesCount == 0)
                    .help("Next Match (Enter / Cmd+G)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(theme.background))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(
                                isFieldFocused
                                    ? Color.accentColor.opacity(0.65)
                                    : Color.primary.opacity(0.12),
                                lineWidth: isFieldFocused ? 1.2 : 0.8
                            )
                    )
            )
        }
    }

    @ViewBuilder
    private var filtersRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text("include:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                SearchTextFieldRepresentable(
                    text: $query.includePattern,
                    placeholder: "e.g. *.swift, src/*",
                    font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    textColor: theme.foreground,
                    placeholderColor: theme.gutterForeground.withAlphaComponent(0.65),
                    isFocused: .constant(false),
                    onSubmit: {
                        lastSubmittedQuery = query
                        onSearch()
                    },
                    onCancel: {
                        onClose()
                    }
                )
                .frame(height: 18)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(theme.background))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
                    )
            )

            HStack(spacing: 6) {
                Text("exclude:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                SearchTextFieldRepresentable(
                    text: $query.excludePattern,
                    placeholder: "e.g. *.min.js, vendor/*",
                    font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    textColor: theme.foreground,
                    placeholderColor: theme.gutterForeground.withAlphaComponent(0.65),
                    isFocused: .constant(false),
                    onSubmit: {
                        lastSubmittedQuery = query
                        onSearch()
                    },
                    onCancel: {
                        onClose()
                    }
                )
                .frame(height: 18)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(theme.background))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 0.8)
                    )
            )

            Spacer()
        }
    }

    @ViewBuilder
    private func toggleButton(
        title: String? = nil,
        icon: String? = nil,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let title = title {
                    Text(title)
                        .font(.system(size: 11, weight: isActive ? .bold : .medium, design: .monospaced))
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: isActive ? .bold : .medium))
                }
            }
            .foregroundColor(isActive ? Color.white : Color(theme.gutterForeground))
            .frame(width: 24, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
