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
        VStack(alignment: .leading, spacing: 6) {
            localProjectSection
            Divider()
                .padding(.horizontal, 4)
            remoteDiffSection
            if hasRecentsOrPresets {
                Divider()
                    .padding(.horizontal, 4)
                recentAndExamplesSection
            }
        }
        .padding(isInline ? 12 : 6)
        .frame(width: isInline ? 440 : 360)
        .overlay(dropOverlay)
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.text], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    @ViewBuilder
    private var localProjectSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("LOCAL PROJECT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("Drag & drop folder anywhere")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 4)
            .padding(.top, isInline ? 0 : 2)

            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))

                TextField("~/path/to/project or /Users/...", text: $localPathInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { submitLocalPath() }

                if !localPathInput.isEmpty {
                    Button(action: {
                        localPathInput = ""
                        localErrorMessage = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }

                if !localPathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: submitLocalPath) {
                        Text("Open")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button(action: onOpenLocalFolder) {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("Browse...")
                            .font(.system(size: 11))
                    }
                }
                .keyboardShortcut("o", modifiers: .command)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Browse folder (Cmd+O)")
            }
            .padding(6)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(localErrorMessage == nil ? Color.secondary.opacity(0.12) : Color.red.opacity(0.7), lineWidth: 0.8)
            )
            .padding(.horizontal, 4)

            if let error = localErrorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder
    private var remoteDiffSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("GITHUB PR / COMMIT / URL")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))

                TextField("https://github.com/... or owner/repo#123", text: $remoteURLInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { submitRemoteURL() }

                if !remoteURLInput.isEmpty {
                    Button(action: {
                        remoteURLInput = ""
                        remoteErrorMessage = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: pasteRemoteFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Paste from clipboard")

                Button(action: submitRemoteURL) {
                    Text("Open")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(6)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(remoteErrorMessage == nil ? Color.secondary.opacity(0.12) : Color.red.opacity(0.7), lineWidth: 0.8)
            )
            .padding(.horizontal, 4)

            if let error = remoteErrorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder
    private var recentAndExamplesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !recentManager.recentLocalPaths.isEmpty {
                Text("RECENT PROJECTS (\(recentManager.recentLocalPaths.count))")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)

                ScrollView(.vertical, showsIndicators: recentManager.recentLocalPaths.count > 5) {
                    VStack(spacing: 2) {
                        ForEach(recentManager.recentLocalPaths, id: \.self) { path in
                            RecentLocalRowView(
                                path: path,
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
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: min(CGFloat(recentManager.recentLocalPaths.count) * 38.0, 220.0))
            }

            if !visiblePresets.isEmpty {
                if !recentManager.recentLocalPaths.isEmpty {
                    Divider()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }

                Text("EXAMPLES")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)

                HStack(spacing: 6) {
                    ForEach(visiblePresets) { preset in
                        PresetChipView(
                            preset: preset,
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
                .padding(.horizontal, 4)
                .padding(.top, 1)
            }
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.5))
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 28))
                        .foregroundColor(.accentColor)
                    Text("Drop folder or URL here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isCurrent ? .accentColor : .secondary)
                        .frame(width: 14)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(folderName)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(path)
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.secondary.opacity(isCrossHovered ? 1.0 : 0.55))
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
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundColor(.secondary.opacity(isCrossHovered ? 1.0 : 0.55))
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
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.secondary.opacity(0.18) : Color.primary.opacity(0.06))
                .animation(.easeInOut(duration: 0.1), value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isHovered ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.12), lineWidth: 0.8)
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
