import SwiftUI
import AppKit
import AnyDiffCore

/// State model managing command-line suggestions for the terminal input bar.
@MainActor
public final class TerminalSuggestionState: ObservableObject {
    @Published public var items: [TerminalCompletionItem] = []
    @Published public var selectedIndex: Int = 0
    @Published public var isVisible: Bool = false
    @Published public var tokenPrefix: String = ""
    public var replaceRange: NSRange = NSRange(location: 0, length: 0)
    public var hasUserNavigated: Bool = false
    public var onApply: ((TerminalCompletionItem) -> Void)?

    public init() {}

    public static let maxSuggestions: Int = 5

    public func show(items: [TerminalCompletionItem], replaceRange: NSRange, tokenPrefix: String) {
        let capped = Array(items.prefix(Self.maxSuggestions))
        guard !capped.isEmpty else {
            hide()
            return
        }
        self.items = capped
        self.replaceRange = replaceRange
        self.tokenPrefix = tokenPrefix
        self.selectedIndex = 0
        self.hasUserNavigated = false
        self.isVisible = true
    }

    public func hide() {
        self.isVisible = false
        self.items.removeAll(keepingCapacity: true)
        self.selectedIndex = 0
        self.hasUserNavigated = false
    }

    public func selectNext() {
        guard !items.isEmpty else { return }
        hasUserNavigated = true
        selectedIndex = (selectedIndex + 1) % items.count
    }

    public func selectPrevious() {
        guard !items.isEmpty else { return }
        hasUserNavigated = true
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
    }

    public var selectedItem: TerminalCompletionItem? {
        guard isVisible, !items.isEmpty, selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }
}

/// Bottom input bar for the block-based terminal, supporting folder context, command history, and execution/cancellation.
public struct TerminalInputBarView: View {
    @ObservedObject public var session: BlockTerminalSession
    public var theme: Theme

    @StateObject private var suggestionState = TerminalSuggestionState()
    @State private var inputText: String = ""
    @State private var historyIndex: Int? = nil
    @State private var temporaryDraft: String = ""
    @State private var isFieldFocused: Bool = false
    @State private var barWidth: CGFloat = 400
    @State private var calculatedHeight: CGFloat = 18
    @State private var isFolderBadgeHovered: Bool = false

    public var onSwitchToInteractive: (() -> Void)?

    public init(session: BlockTerminalSession, theme: Theme, onSwitchToInteractive: (() -> Void)? = nil) {
        self.session = session
        self.theme = theme
        self.onSwitchToInteractive = onSwitchToInteractive
    }

    private var isCompact: Bool {
        barWidth < 280
    }

    private var isUltraCompact: Bool {
        barWidth < 200
    }

    private var folderName: String {
        let home = NSHomeDirectory()
        if session.currentDirectory == home {
            return "~"
        }
        let last = (session.currentDirectory as NSString).lastPathComponent
        return last.isEmpty ? session.currentDirectory : last
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Autocompletion suggestions card (rises above the prompt bar)
            if suggestionState.isVisible && !suggestionState.items.isEmpty {
                HStack(spacing: 0) {
                    suggestionsCard
                        .frame(width: min(250, max(180, barWidth - (isCompact ? 12 : 20))))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, isCompact ? 6 : 10)
                .padding(.bottom, 0)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }

            // Elevated single-line floating prompt bar
            inputRow
                .padding(.horizontal, isCompact ? 6 : 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(theme.inputBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            Color(theme.gutterForeground).opacity(isFieldFocused ? 0.35 : 0.18),
                            lineWidth: 1.0
                        )
                )
                .shadow(
                    color: Color.black.opacity(isFieldFocused ? 0.08 : 0.04),
                    radius: isFieldFocused ? 4 : 2,
                    y: 1
                )
                .padding(.horizontal, isCompact ? 6 : 10)
                .padding(.top, suggestionState.isVisible && !suggestionState.items.isEmpty ? 2 : 4)
                .padding(.bottom, 6)
                .animation(.easeInOut(duration: 0.14), value: isFieldFocused)
                .animation(.easeInOut(duration: 0.12), value: calculatedHeight)
        }
        .animation(.easeInOut(duration: 0.14), value: suggestionState.isVisible)
        .background(
            GeometryReader { geo in
                Color.clear
                    .preference(key: TerminalInputBarWidthPreferenceKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(TerminalInputBarWidthPreferenceKey.self) { newWidth in
            if newWidth > 0 && abs(newWidth - barWidth) > 1 {
                barWidth = newWidth
            }
        }
        .background(Color(theme.background))
    }

    // MARK: - Subviews

    @ViewBuilder
    private var inputRow: some View {
        HStack(alignment: .top, spacing: isCompact ? 5 : 6) {
            Text("❯")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(session.isProcessRunning ? Color.orange : Color(theme.accentColor))
                .frame(height: 20)
                .fixedSize()

            TerminalCommandTextView(
                text: $inputText,
                calculatedHeight: $calculatedHeight,
                session: session,
                suggestionState: suggestionState,
                textColor: theme.foreground,
                isFocused: $isFieldFocused,
                onCommit: submitCommand,
                onCancel: {
                    if suggestionState.isVisible {
                        suggestionState.hide()
                    } else if session.isProcessRunning {
                        session.sendInterrupt()
                    } else {
                        inputText = ""
                        calculatedHeight = 18
                        suggestionState.hide()
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: min(max(18, calculatedHeight), 120))
            .padding(.top, 1)

            if !isUltraCompact {
                Menu {
                    folderMenuContent
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                        Text(folderName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .opacity(isFolderBadgeHovered ? 0.75 : 0.35)
                    }
                    .foregroundColor(Color(theme.accentColor).opacity(isFolderBadgeHovered ? 1.0 : 0.85))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(theme.accentColor).opacity(isFolderBadgeHovered ? 0.12 : 0))
                    )
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .onHover { isFolderBadgeHovered = $0 }
                .frame(height: 20)
                .help("Current directory: \(session.currentDirectory)\nClick to choose or jump to folder")
                .fixedSize()
            }
        }
    }

    // MARK: - Suggestions Card

    @ViewBuilder
    private var suggestionsCard: some View {
        VStack(spacing: 1) {
            // Display suggestions in reverse order (bottom-up), so that item 0
            // (the primary/best match) is at the bottom, directly adjacent to the input prompt.
            ForEach(Array(suggestionState.items.enumerated().reversed()), id: \.element.id) { index, item in
                suggestionRow(item: item, isSelected: index == suggestionState.selectedIndex)
                    .id(index)
                    .onTapGesture {
                        suggestionState.onApply?(item)
                    }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(theme.inputBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(theme.gutterForeground).opacity(0.22), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(0.14), radius: 4, y: -1)
    }

    @ViewBuilder
    private func suggestionRow(item: TerminalCompletionItem, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            suggestionIcon(for: item.kind)
                .frame(width: 13, height: 13)

            highlightedText(text: item.label, query: suggestionState.tokenPrefix)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundColor(isSelected ? Color(theme.foreground) : Color(theme.foreground).opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 9.5, design: .default))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isSelected ? 0.85 : 0.55))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color(theme.accentColor).opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func highlightedText(text: String, query: String) -> some View {
        let matchQuery: String = query.split(separator: "/").last.map(String.init) ?? query
        if !matchQuery.isEmpty && text.lowercased().hasPrefix(matchQuery.lowercased()) {
            let matchLen = matchQuery.count
            let matchPart = String(text.prefix(matchLen))
            let restPart = String(text.dropFirst(matchLen))
            HStack(spacing: 0) {
                Text(matchPart)
                    .foregroundColor(Color(theme.accentColor))
                    .fontWeight(.bold)
                Text(restPart)
            }
        } else if !matchQuery.isEmpty, let range = text.range(of: matchQuery, options: .caseInsensitive) {
            let before = String(text[..<range.lowerBound])
            let match = String(text[range])
            let after = String(text[range.upperBound...])
            HStack(spacing: 0) {
                Text(before)
                Text(match)
                    .foregroundColor(Color(theme.accentColor))
                    .fontWeight(.bold)
                Text(after)
            }
        } else {
            Text(text)
        }
    }

    @ViewBuilder
    private func suggestionIcon(for kind: TerminalCompletionItem.Kind) -> some View {
        switch kind {
        case .directory:
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundColor(Color(theme.accentColor))
        case .file:
            Image(systemName: "doc")
                .font(.system(size: 10))
                .foregroundColor(Color(theme.gutterForeground))
        case .command:
            Image(systemName: "terminal")
                .font(.system(size: 9.5))
                .foregroundColor(Color.green)
        case .subcommand:
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(Color.orange)
        case .gitBranch:
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9.5))
                .foregroundColor(Color.purple)
        case .recipe:
            Image(systemName: "hammer.fill")
                .font(.system(size: 9.5))
                .foregroundColor(Color.yellow)
        case .history:
            Image(systemName: "clock")
                .font(.system(size: 9.5))
                .foregroundColor(Color(theme.gutterForeground))
        case .flag:
            Image(systemName: "minus")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundColor(Color.blue)
        }
    }

    private func submitCommand() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        calculatedHeight = 18
        suggestionState.hide()
        session.execute(command: trimmed)
    }

    // MARK: - Directory Switching & Selector

    private struct ParentDirectoryItem: Identifiable {
        var id: String { path }
        let name: String
        let path: String
    }

    private var parentDirectories: [ParentDirectoryItem] {
        var items: [ParentDirectoryItem] = []
        var cur = session.currentDirectory as NSString
        let home = NSHomeDirectory()

        while cur.length > 1 {
            let parent = cur.deletingLastPathComponent
            if parent == (cur as String) { break }
            let name = (parent == home) ? "~ (Home)" : ((parent as NSString).lastPathComponent.isEmpty ? "/" : (parent as NSString).lastPathComponent)
            items.append(ParentDirectoryItem(name: name, path: parent))
            cur = parent as NSString
        }
        return items
    }

    private var subdirectories: [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: session.currentDirectory) else {
            return []
        }
        return entries
            .filter { !$0.hasPrefix(".") }
            .filter { entry in
                var isDir: ObjCBool = false
                let full = (session.currentDirectory as NSString).appendingPathComponent(entry)
                return fm.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var gitRootDirectory: String? {
        var cur = session.currentDirectory as NSString
        let fm = FileManager.default
        while cur.length > 1 {
            let gitPath = cur.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                return cur as String
            }
            let parent = cur.deletingLastPathComponent
            if parent == (cur as String) { break }
            cur = parent as NSString
        }
        return nil
    }

    private func changeDirectory(to path: String) {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        session.execute(command: "cd \"\(escaped)\"")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: session.currentDirectory)
        panel.prompt = "Select"
        panel.message = "Choose working directory for terminal"
        if panel.runModal() == .OK, let url = panel.url {
            changeDirectory(to: url.path)
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.currentDirectory)
    }

    private func copyCurrentPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(session.currentDirectory, forType: .string)
    }

    @ViewBuilder
    private var folderMenuContent: some View {
        Button(action: chooseFolder) {
            Label("Choose Folder…", systemImage: "folder.badge.plus")
        }
        Button(action: revealInFinder) {
            Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
        }
        Button(action: copyCurrentPath) {
            Label("Copy Path", systemImage: "doc.on.doc")
        }

        Divider()

        // Quick parent jump
        if let parent = parentDirectories.first {
            Button("Go to Parent (..)") {
                changeDirectory(to: parent.path)
            }
        }

        // Git Root jump
        if let gitRoot = gitRootDirectory, gitRoot != session.currentDirectory {
            let rootName = (gitRoot as NSString).lastPathComponent
            Button("Go to Git Root (\(rootName))") {
                changeDirectory(to: gitRoot)
            }
        }

        // Home jump
        let home = NSHomeDirectory()
        if session.currentDirectory != home {
            Button("Go to Home (~)") {
                changeDirectory(to: home)
            }
        }

        // Enclosing Folders submenu
        if parentDirectories.count > 1 {
            Divider()
            Menu("Enclosing Folders") {
                ForEach(parentDirectories) { item in
                    Button(item.name) {
                        changeDirectory(to: item.path)
                    }
                }
            }
        }

        // Subfolders submenu
        let subs = subdirectories
        if !subs.isEmpty {
            Menu("Subfolders (\(subs.count))") {
                ForEach(subs.prefix(25), id: \.self) { sub in
                    Button(sub) {
                        let full = (session.currentDirectory as NSString).appendingPathComponent(sub)
                        changeDirectory(to: full)
                    }
                }
                if subs.count > 25 {
                    Text("…and \(subs.count - 25) more")
                }
            }
        }
    }
}

/// AppKit multiline text view with auto-expanding height, arrow key history navigation, Enter / Shift+Enter handling, and Tab completion.
private struct TerminalCommandTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    var session: BlockTerminalSession
    var suggestionState: TerminalSuggestionState
    var textColor: NSColor
    @Binding var isFocused: Bool
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = KeyCatchingTextView()
        textView.isProcessRunning = session.isProcessRunning
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.keyDelegate = context.coordinator
        textView.string = text
        textView.onFocusChanged = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.isFocused = focused
            if !focused {
                coordinator?.parent.suggestionState.hide()
            }
        }
        textView.onHeightChanged = { [weak coordinator = context.coordinator] newHeight in
            coordinator?.reportHeight(newHeight)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        context.coordinator.bindSuggestions()

        DispatchQueue.main.async {
            textView.recalculateHeight()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.bindSuggestions()

        guard let tv = scrollView.documentView as? KeyCatchingTextView else { return }
        tv.isProcessRunning = session.isProcessRunning
        tv.textColor = textColor
        tv.insertionPointColor = textColor

        if tv.string != text {
            tv.string = text
            tv.recalculateHeight()
        }

        let neededHeight = tv.contentHeight
        let shouldScroll = neededHeight > 120
        if scrollView.hasVerticalScroller != shouldScroll {
            scrollView.hasVerticalScroller = shouldScroll
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, KeyCatchingTextViewDelegate {
        var parent: TerminalCommandTextView
        var historyCursor: Int? = nil
        var currentDraft: String = ""
        weak var textView: KeyCatchingTextView?
        weak var scrollView: NSScrollView?

        init(_ parent: TerminalCommandTextView) {
            self.parent = parent
        }

        func bindSuggestions() {
            parent.suggestionState.onApply = { [weak self] item in
                guard let self = self else { return }
                self.applyCompletion(item, replaceRange: self.parent.suggestionState.replaceRange)
                if let tv = self.textView {
                    self.updateSuggestions(tv: tv)
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? KeyCatchingTextView else { return }
            let newText = tv.string
            if parent.text != newText {
                parent.text = newText
            }
            if historyCursor == nil {
                currentDraft = newText
            }
            tv.recalculateHeight()

            // Update suggestions live as the user types (auto-suggest / intellisense)
            updateSuggestions(tv: tv)
        }

        func updateSuggestions(tv: KeyCatchingTextView) {
            // Only update/filter suggestions if completion was explicitly triggered (e.g. via Tab)
            guard parent.suggestionState.isVisible else { return }
            let trimmed = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                parent.suggestionState.hide()
                return
            }

            let cursor = tv.selectedRange().location
            let result = TerminalCompletionEngine.shared.completions(
                text: tv.string,
                cursorLocation: cursor,
                currentDirectory: parent.session.currentDirectory,
                commandHistory: parent.session.commandHistory
            )

            if result.items.isEmpty {
                parent.suggestionState.hide()
            } else {
                parent.suggestionState.show(
                    items: result.items,
                    replaceRange: result.replaceRange,
                    tokenPrefix: result.tokenPrefix
                )
            }
        }

        func reportHeight(_ h: CGFloat) {
            if abs(parent.calculatedHeight - h) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.calculatedHeight = h
                }
            }
        }

        func onCommit() {
            // If the user explicitly navigated through the suggestion list with arrow keys, apply the chosen item
            if parent.suggestionState.isVisible && parent.suggestionState.hasUserNavigated,
               let item = parent.suggestionState.selectedItem {
                applyCompletion(item, replaceRange: parent.suggestionState.replaceRange)
                if let tv = textView {
                    updateSuggestions(tv: tv)
                }
                return
            }
            parent.suggestionState.hide()
            parent.onCommit()
            historyCursor = nil
            currentDraft = ""
        }

        func onCancel() {
            if parent.suggestionState.isVisible {
                parent.suggestionState.hide()
                return
            }
            historyCursor = nil
            currentDraft = ""
            parent.onCancel()
        }

        func onUpArrow() {
            if parent.suggestionState.isVisible {
                // In reverse (bottom-up) view, pressing Up moves physically UP to higher indices
                parent.suggestionState.selectNext()
                return
            }

            guard !parent.session.commandHistory.isEmpty else { return }
            let history = parent.session.commandHistory
            if historyCursor == nil {
                currentDraft = parent.text
                historyCursor = history.count - 1
            } else if let cur = historyCursor, cur > 0 {
                historyCursor = cur - 1
            }

            if let idx = historyCursor, idx >= 0 && idx < history.count {
                let val = history[idx]
                parent.text = val
                if let tv = textView {
                    tv.string = val
                    tv.selectedRange = NSRange(location: (val as NSString).length, length: 0)
                    tv.recalculateHeight()
                }
            }
        }

        func onDownArrow() {
            if parent.suggestionState.isVisible {
                // In reverse (bottom-up) view, pressing Down moves physically DOWN towards 0 (bottom)
                parent.suggestionState.selectPrevious()
                return
            }

            let history = parent.session.commandHistory
            guard let cur = historyCursor else { return }
            if cur + 1 < history.count {
                let nextIdx = cur + 1
                historyCursor = nextIdx
                let val = history[nextIdx]
                parent.text = val
                if let tv = textView {
                    tv.string = val
                    tv.selectedRange = NSRange(location: (val as NSString).length, length: 0)
                    tv.recalculateHeight()
                }
            } else {
                historyCursor = nil
                parent.text = currentDraft
                if let tv = textView {
                    tv.string = currentDraft
                    tv.selectedRange = NSRange(location: (currentDraft as NSString).length, length: 0)
                    tv.recalculateHeight()
                }
            }
        }

        func onRightArrow() -> Bool {
            if parent.suggestionState.isVisible, let item = parent.suggestionState.selectedItem {
                applyCompletion(item, replaceRange: parent.suggestionState.replaceRange)
                if let tv = textView {
                    updateSuggestions(tv: tv)
                }
                return true
            }
            return false
        }

        func onTab(isShift: Bool) {
            guard let tv = textView else { return }

            // If suggestions card is visible AND still valid for current cursor token, Tab applies the selected completion item
            if parent.suggestionState.isVisible {
                let cursor = tv.selectedRange().location
                let (_, _, parseRange) = TerminalCompletionEngine.shared.parseTokens(text: tv.string, cursorLocation: cursor)
                let ns = tv.string as NSString
                if parseRange.location + parseRange.length <= ns.length {
                    let currentPrefix = ns.substring(with: parseRange)
                    if parseRange == parent.suggestionState.replaceRange &&
                       currentPrefix == parent.suggestionState.tokenPrefix {
                        if let item = parent.suggestionState.selectedItem {
                            applyCompletion(item, replaceRange: parseRange)
                            updateSuggestions(tv: tv)
                            return
                        }
                    }
                }
                parent.suggestionState.hide()
            }

            let cursor = tv.selectedRange().location
            let textToComplete = (tv.string as NSString).substring(to: max(0, min(cursor, tv.string.utf16.count)))

            if !parent.session.isProcessRunning {
                parent.session.requestNativeCompletions(commandLine: textToComplete) { [weak self, weak tv] nativeItems in
                    guard let self = self, let tv = tv else { return }
                    if !nativeItems.isEmpty {
                        let (_, _, replaceRange) = TerminalCompletionEngine.shared.parseTokens(
                            text: tv.string,
                            cursorLocation: tv.selectedRange().location
                        )
                        let tokenPrefix = (tv.string as NSString).substring(with: replaceRange)
                        let result = TerminalCompletionResult(
                            items: nativeItems,
                            replaceRange: replaceRange,
                            tokenPrefix: tokenPrefix
                        )
                        self.handleCompletionResult(result, tv: tv)
                        return
                    }
                    self.performLocalTabCompletion(tv: tv)
                }
                return
            }

            performLocalTabCompletion(tv: tv)
        }

        func performLocalTabCompletion(tv: KeyCatchingTextView) {
            let cursor = tv.selectedRange().location
            let result = TerminalCompletionEngine.shared.completions(
                text: tv.string,
                cursorLocation: cursor,
                currentDirectory: parent.session.currentDirectory,
                commandHistory: parent.session.commandHistory
            )
            handleCompletionResult(result, tv: tv)
        }

        func handleCompletionResult(_ result: TerminalCompletionResult, tv: KeyCatchingTextView) {
            if result.items.isEmpty {
                NSSound.beep()
                return
            }

            if result.items.count == 1, let single = result.items.first {
                applyCompletion(single, replaceRange: result.replaceRange)
                updateSuggestions(tv: tv)
                return
            }

            // Multiple items: if common prefix is longer than current typed prefix, complete it
            if let common = result.longestCommonPrefix, common.count > result.tokenPrefix.count {
                applyInlineText(common, replaceRange: result.replaceRange)
                let commonNsLen = (common as NSString).length
                let newRange = NSRange(location: result.replaceRange.location, length: commonNsLen)
                parent.suggestionState.show(items: result.items, replaceRange: newRange, tokenPrefix: common)
            } else {
                parent.suggestionState.show(items: result.items, replaceRange: result.replaceRange, tokenPrefix: result.tokenPrefix)
            }
        }

        func applyCompletion(_ item: TerminalCompletionItem, replaceRange: NSRange) {
            applyInlineText(item.insertText, replaceRange: replaceRange)
            parent.suggestionState.hide()
        }

        func applyInlineText(_ insertText: String, replaceRange: NSRange) {
            guard let tv = textView else { return }
            let current = tv.string as NSString
            guard replaceRange.location <= current.length,
                  replaceRange.location + replaceRange.length <= current.length else { return }

            let newString = current.replacingCharacters(in: replaceRange, with: insertText)
            tv.string = newString
            parent.text = newString
            let newCursor = replaceRange.location + (insertText as NSString).length
            tv.selectedRange = NSRange(location: newCursor, length: 0)
            tv.recalculateHeight()
        }
    }
}

@MainActor
private protocol KeyCatchingTextViewDelegate: AnyObject {
    func onCommit()
    func onCancel()
    func onUpArrow()
    func onDownArrow()
    func onRightArrow() -> Bool
    func onTab(isShift: Bool)
}

@MainActor
private final class KeyCatchingTextView: NSTextView {
    var isProcessRunning: Bool = false
    var onFocusChanged: ((Bool) -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?
    weak var keyDelegate: KeyCatchingTextViewDelegate?
    var contentHeight: CGFloat = 18

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }

    override func insertTab(_ sender: Any?) {
        if !isProcessRunning {
            keyDelegate?.onTab(isShift: false)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if !isProcessRunning {
            keyDelegate?.onTab(isShift: true)
        } else {
            super.insertBacktab(sender)
        }
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertTab(_:)) {
            if !isProcessRunning {
                keyDelegate?.onTab(isShift: false)
                return
            }
        } else if selector == #selector(insertBacktab(_:)) {
            if !isProcessRunning {
                keyDelegate?.onTab(isShift: true)
                return
            }
        } else if selector == #selector(cancelOperation(_:)) {
            keyDelegate?.onCancel()
            return
        }
        super.doCommand(by: selector)
    }

    func recalculateHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let h = max(18, ceil(used.height + 2))
        if abs(contentHeight - h) > 0.5 {
            contentHeight = h
            onHeightChanged?(h)
        }
    }

    func isCursorOnFirstLine() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        if sel.location == 0 { return true }
        let ns = string as NSString
        let textBefore = ns.substring(to: min(sel.location, ns.length))
        if textBefore.contains("\n") {
            return false
        }
        guard let lm = layoutManager, let tc = textContainer else { return true }
        lm.ensureLayout(for: tc)
        let charIdx = min(sel.location, max(0, ns.length - 1))
        let glyphIdx = lm.glyphIndexForCharacter(at: charIdx)
        let cursorRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let firstLineRect = lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return cursorRect.minY <= firstLineRect.minY + 2
    }

    func isCursorOnLastLine() -> Bool {
        let sel = selectedRange()
        let len = (string as NSString).length
        guard sel.length == 0 else { return false }
        if sel.location == len { return true }
        let ns = string as NSString
        let textAfter = ns.substring(from: min(sel.location, ns.length))
        if textAfter.contains("\n") {
            return false
        }
        guard let lm = layoutManager, let tc = textContainer else { return true }
        lm.ensureLayout(for: tc)
        if lm.extraLineFragmentTextContainer != nil {
            return false
        }
        let charIdx = min(sel.location, max(0, len - 1))
        let glyphIdx = lm.glyphIndexForCharacter(at: charIdx)
        let cursorRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let lastGlyph = max(0, lm.numberOfGlyphs - 1)
        let lastLineRect = lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        return cursorRect.maxY >= lastLineRect.maxY - 2
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            onFocusChanged?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            onFocusChanged?(false)
        }
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "c" {
                keyDelegate?.onCancel()
                return true
            }
            if event.keyCode == 53 { // Escape
                keyDelegate?.onCancel()
                return true
            }
            // Tab key inside field editor
            if event.keyCode == 48 {
                if !isProcessRunning {
                    let isShift = event.modifierFlags.contains(.shift)
                    keyDelegate?.onTab(isShift: isShift)
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 { // Enter / Return
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
                recalculateHeight()
                scrollRangeToVisible(selectedRange())
                return
            } else {
                keyDelegate?.onCommit()
                return
            }
        }
        if event.keyCode == 53 { // Escape
            keyDelegate?.onCancel()
            return
        }
        if event.keyCode == 48 { // Tab
            if !isProcessRunning {
                let isShift = event.modifierFlags.contains(.shift)
                keyDelegate?.onTab(isShift: isShift)
                return
            }
        }
        // Ctrl+Space
        if event.modifierFlags.contains(.control) && event.keyCode == 49 {
            if !isProcessRunning {
                keyDelegate?.onTab(isShift: false)
                return
            }
        }
        if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "c" {
            keyDelegate?.onCancel()
            return
        }
        if event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty {
            if event.keyCode == 126 { // Up arrow
                if !isProcessRunning {
                    keyDelegate?.onUpArrow()
                    return
                }
            } else if event.keyCode == 125 { // Down arrow
                if !isProcessRunning {
                    keyDelegate?.onDownArrow()
                    return
                }
            } else if event.keyCode == 124 { // Right arrow
                if !isProcessRunning {
                    let sel = selectedRange()
                    let len = (string as NSString).length
                    if sel.location == len && keyDelegate?.onRightArrow() == true {
                        return
                    }
                }
            }
        }
        super.keyDown(with: event)
        recalculateHeight()
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        recalculateHeight()
    }
}

private struct TerminalInputBarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 400

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
