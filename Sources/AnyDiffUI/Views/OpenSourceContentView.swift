import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnyDiffCore

public struct OpenSourceContentView: View {
    public var theme: Theme
    public var currentLocalPath: String?
    public var currentComparisonTarget: ComparisonTarget?
    public var isInline: Bool
    public var onOpenLocalFolder: () -> Void
    public var onSelectLocalPath: (String) -> Void
    public var onOpenRemoteURL: (String) -> Void
    public var onOpenInBrowser: (() -> Void)?
    public var onClose: (() -> Void)?

    @ObservedObject private var recentManager = RecentSourcesManager.shared
    @State private var localPathInput: String = ""
    @State private var remoteURLInput: String = ""
    @State private var localErrorMessage: String? = nil
    @State private var remoteErrorMessage: String? = nil
    @State private var isDropTargeted: Bool = false

    public struct PresetExample: Identifiable {
        public var id: String { url }
        public let title: String
        public let url: String
        public let isMega: Bool
    }

    public let presets: [PresetExample] = [
        PresetExample(title: "bun #30412", url: "https://github.com/oven-sh/bun/pull/30412", isMega: true),
        PresetExample(title: "ghostty #12291", url: "https://github.com/ghostty-org/ghostty/pull/12291", isMega: false),
        PresetExample(title: "nodejs #59805", url: "https://github.com/nodejs/node/pull/59805", isMega: false)
    ]

    private var visiblePresets: [PresetExample] {
        presets.filter { !recentManager.isPresetDismissed(url: $0.url) }
    }

    private var hasRecentsOrPresets: Bool {
        !recentManager.recentLocalPaths.isEmpty || !visiblePresets.isEmpty
    }

    public init(
        theme: Theme,
        currentLocalPath: String? = nil,
        currentComparisonTarget: ComparisonTarget? = nil,
        isInline: Bool = false,
        onOpenLocalFolder: @escaping () -> Void,
        onSelectLocalPath: @escaping (String) -> Void,
        onOpenRemoteURL: @escaping (String) -> Void,
        onOpenInBrowser: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.theme = theme
        self.currentLocalPath = currentLocalPath
        self.currentComparisonTarget = currentComparisonTarget
        self.isInline = isInline
        self.onOpenLocalFolder = onOpenLocalFolder
        self.onSelectLocalPath = onSelectLocalPath
        self.onOpenRemoteURL = onOpenRemoteURL
        self.onOpenInBrowser = onOpenInBrowser
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            localProjectSection
            Divider()
            remoteDiffSection
            if hasRecentsOrPresets {
                Divider()
                recentAndExamplesSection
            }
        }
        .padding(14)
        .frame(width: isInline ? 460 : 420)
        .background(Color(theme.background))
        .overlay(dropOverlay)
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.text], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    @ViewBuilder
    private var localProjectSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Local Project", systemImage: "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))
                Spacer()
                Text("Drag & drop folder anywhere")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("~/path/to/project or /Users/...", text: $localPathInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(theme.foreground))
                        .onSubmit { submitLocalPath() }

                    if !localPathInput.isEmpty {
                        Button(action: {
                            localPathInput = ""
                            localErrorMessage = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(theme.gutterForeground))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(theme.gutterBackground))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(localErrorMessage == nil ? Color(theme.excerptHeaderBorder) : Color.red.opacity(0.7), lineWidth: 1)
                )

                if !localPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: submitLocalPath) {
                        Text("Open")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button(action: onOpenLocalFolder) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Browse...")
                            .font(.system(size: 11.5))
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Browse folder (Cmd+O)")
            }

            if let error = localErrorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder
    private var remoteDiffSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("GitHub PR / Commit / URL", systemImage: "globe")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(theme.foreground))
                Spacer()
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    TextField("https://github.com/... or owner/repo#123", text: $remoteURLInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(theme.foreground))
                        .onSubmit { submitRemoteURL() }

                    if !remoteURLInput.isEmpty {
                        Button(action: {
                            remoteURLInput = ""
                            remoteErrorMessage = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(Color(theme.gutterForeground))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: pasteRemoteFromClipboard) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 11))
                            .foregroundColor(Color(theme.gutterForeground))
                    }
                    .buttonStyle(.plain)
                    .help("Paste from clipboard")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(theme.gutterBackground))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(remoteErrorMessage == nil ? Color(theme.excerptHeaderBorder) : Color.red.opacity(0.7), lineWidth: 1)
                )

                Button(action: submitRemoteURL) {
                    Text("Open")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = remoteErrorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.leading, 2)
            }
        }
    }

    @ViewBuilder
    private var recentAndExamplesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("RECENT & EXAMPLES")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(theme.gutterForeground))
                .padding(.bottom, 1)

            if !recentManager.recentLocalPaths.isEmpty {
                ScrollView(.vertical, showsIndicators: recentManager.recentLocalPaths.count > 4) {
                    VStack(spacing: 2) {
                        ForEach(recentManager.recentLocalPaths, id: \.self) { path in
                            RecentLocalRowView(
                                path: path,
                                theme: theme,
                                isCurrent: (path == currentLocalPath),
                                onSelect: { onSelectLocalPath(path) },
                                onRemove: {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        recentManager.removeLocalPath(path)
                                    }
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(recentManager.recentLocalPaths.count) * 30.0, 160.0))
            }

            if !visiblePresets.isEmpty {
                HStack(spacing: 6) {
                    ForEach(visiblePresets) { preset in
                        PresetChipView(
                            preset: preset,
                            theme: theme,
                            onSelect: { onOpenRemoteURL(preset.url) },
                            onDismiss: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    recentManager.dismissPreset(url: preset.url)
                                }
                            }
                        )
                    }

                    Spacer()

                    if case .remote = currentComparisonTarget, let onOpenInBrowser = onOpenInBrowser {
                        Button(action: onOpenInBrowser) {
                            HStack(spacing: 3) {
                                Text("Open in Browser")
                                    .font(.system(size: 10))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(PlainHoverButtonStyle())
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(theme.background).opacity(0.92))
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                    Text("Drop folder or URL here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(theme.foreground))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            .padding(4)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL?
                if let url = item as? URL {
                    targetURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    targetURL = url
                } else if let string = item as? String, let url = URL(string: string) {
                    targetURL = url
                }
                if let url = targetURL {
                    DispatchQueue.main.async {
                        let path = url.path
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                            if isDir.boolValue {
                                onSelectLocalPath(path)
                            } else {
                                onSelectLocalPath((path as NSString).deletingLastPathComponent)
                            }
                        }
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                var stringVal: String?
                if let url = item as? URL {
                    stringVal = url.absoluteString
                } else if let str = item as? String {
                    stringVal = str
                }
                if let str = stringVal {
                    DispatchQueue.main.async {
                        onOpenRemoteURL(str)
                    }
                }
            }
            return true
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    DispatchQueue.main.async {
                        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                            let expanded = (trimmed as NSString).expandingTildeInPath
                            if FileManager.default.fileExists(atPath: expanded) {
                                onSelectLocalPath(expanded)
                                return
                            }
                        }
                        onOpenRemoteURL(trimmed)
                    }
                }
            }
            return true
        }
        return false
    }

    private func submitLocalPath() {
        let trimmed = localPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let expanded = (trimmed as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) {
            localErrorMessage = nil
            onSelectLocalPath(expanded)
        } else {
            localErrorMessage = "Directory not found: \(trimmed)"
        }
    }

    private func pasteRemoteFromClipboard() {
        if let clipboard = NSPasteboard.general.string(forType: .string) {
            remoteURLInput = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            remoteErrorMessage = nil
        }
    }

    private func submitRemoteURL() {
        let trimmed = remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch GitHubDiffService.shared.parseReference(from: trimmed) {
        case .success:
            remoteErrorMessage = nil
            onOpenRemoteURL(trimmed)
        case .failure(let err):
            remoteErrorMessage = err.localizedDescription
        }
    }
}

private struct RecentLocalRowView: View {
    let path: String
    let theme: Theme
    let isCurrent: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered: Bool = false
    @State private var isCrossHovered: Bool = false

    var body: some View {
        let folderName = URL(fileURLWithPath: path).lastPathComponent

        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: isCurrent ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundColor(isCurrent ? .accentColor : Color(theme.gutterForeground))
                        .frame(width: 14)

                    Text(folderName)
                        .font(.system(size: 11.5, weight: isCurrent ? .bold : .medium))
                        .foregroundColor(Color(theme.foreground))

                    Spacer()

                    Text(path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(Color(theme.gutterForeground).opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isCrossHovered ? 1.0 : 0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.0)
            .allowsHitTesting(isHovered)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
            .onHover { crossHover in
                isCrossHovered = crossHover
            }
            .help("Remove from recents")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct PresetChipView: View {
    let preset: OpenSourceContentView.PresetExample
    let theme: Theme
    let onSelect: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered: Bool = false
    @State private var isCrossHovered: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    if preset.isMega {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                    Text(preset.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(theme.foreground))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundColor(Color(theme.gutterForeground).opacity(isCrossHovered ? 1.0 : 0.55))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.0)
            .allowsHitTesting(isHovered)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
            .onHover { crossHover in
                isCrossHovered = crossHover
            }
            .help("Remove example")
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.secondary.opacity(0.18) : Color(theme.gutterBackground))
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isHovered ? Color.accentColor.opacity(0.5) : Color(theme.excerptHeaderBorder), lineWidth: 0.8)
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

public struct OpenRowHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.secondary.opacity(configuration.isPressed ? 0.2 : 0.1) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

public struct PlainHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isHovered ? 1.0 : (configuration.isPressed ? 0.5 : 0.65))
            .scaleEffect(isHovered ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
