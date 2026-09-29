import SwiftUI
import UniformTypeIdentifiers
import AnyDiffCore

public struct WindowDropOverlayView: View {
    public let theme: Theme

    public init(theme: Theme) {
        self.theme = theme
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 44, weight: .light))
                    .foregroundColor(.accentColor)
                Text("Drop folder or URL to open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(theme.background).opacity(0.95))
                    .shadow(color: .black.opacity(0.35), radius: 24)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, lineWidth: 2)
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

public struct WindowDropModifier: ViewModifier {
    @Binding public var isTargeted: Bool
    public let theme: Theme
    public let onOpenFolder: (String) -> Void
    public let onOpenRemote: (String) -> Void

    public init(
        isTargeted: Binding<Bool>,
        theme: Theme,
        onOpenFolder: @escaping (String) -> Void,
        onOpenRemote: @escaping (String) -> Void
    ) {
        self._isTargeted = isTargeted
        self.theme = theme
        self.onOpenFolder = onOpenFolder
        self.onOpenRemote = onOpenRemote
    }

    public func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL, UTType.url, UTType.text], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
            .overlay {
                if isTargeted {
                    WindowDropOverlayView(theme: theme)
                }
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
                                onOpenFolder(path)
                            } else {
                                onOpenFolder((path as NSString).deletingLastPathComponent)
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
                        onOpenRemote(str)
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
                                onOpenFolder(expanded)
                                return
                            }
                        }
                        onOpenRemote(trimmed)
                    }
                }
            }
            return true
        }
        return false
    }
}
