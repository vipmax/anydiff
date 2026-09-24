import SwiftUI
import AppKit
import Combine
import AnyDiffCore

public struct MarkdownDocumentView: View {
    public let filePath: String
    public let rootDirectory: String
    public let theme: Theme
    public var onClose: () -> Void
    public var onOpenInEditor: () -> Void

    @State private var content: String = ""
    @State private var blocks: [MarkdownBlock] = []
    @State private var scrollToHeaderIndex: Int? = nil
    @State private var fileWatcher: FolderWatcher? = nil

    public init(
        filePath: String,
        rootDirectory: String,
        theme: Theme,
        onClose: @escaping () -> Void,
        onOpenInEditor: @escaping () -> Void
    ) {
        self.filePath = filePath
        self.rootDirectory = rootDirectory
        self.theme = theme
        self.onClose = onClose
        self.onOpenInEditor = onOpenInEditor

        let fullPath = (filePath as NSString).isAbsolutePath ? filePath : (rootDirectory as NSString).appendingPathComponent(filePath)
        if FileManager.default.fileExists(atPath: fullPath),
           let raw = try? String(contentsOfFile: fullPath, encoding: .utf8) {
            _content = State(initialValue: raw)
            _blocks = State(initialValue: MarkdownParser.parse(raw))
        } else {
            _content = State(initialValue: "")
            _blocks = State(initialValue: [])
        }
    }

    private var resolvedFullPath: String {
        if (filePath as NSString).isAbsolutePath {
            return filePath
        }
        return (rootDirectory as NSString).appendingPathComponent(filePath)
    }

    public var body: some View {
        MarkdownNativeScrollViewRepresentable(
            blocks: blocks,
            theme: theme,
            filePath: resolvedFullPath,
            rootDirectory: rootDirectory,
            scrollToHeaderIndex: scrollToHeaderIndex,
            onClose: onClose
        )
        .background(Color(theme.background))
        .background(
            HStack {
                Button(action: onOpenInEditor) { EmptyView() }
                    .keyboardShortcut("e", modifiers: .command)
                Button(action: onClose) { EmptyView() }
                    .keyboardShortcut(.cancelAction)
            }
            .opacity(0)
        )
        .onAppear {
            loadFileContent()
            setupWatcher()
        }
        .onChange(of: filePath) { _ in
            loadFileContent()
            setupWatcher()
        }
        .onDisappear {
            fileWatcher?.stop()
            fileWatcher = nil
        }
    }

    // MARK: - File Loading & Watching

    private func loadFileContent() {
        let path = resolvedFullPath
        guard FileManager.default.fileExists(atPath: path),
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            content = ""
            blocks = []
            return
        }

        content = raw
        blocks = MarkdownParser.parse(raw)
    }

    private func setupWatcher() {
        fileWatcher?.stop()
        let targetPath = URL(fileURLWithPath: resolvedFullPath).resolvingSymlinksInPath().path
        let parentURL = URL(fileURLWithPath: targetPath).deletingLastPathComponent()

        let watcher = FolderWatcher(url: parentURL, latency: 0.15) { events in
            let hit = events.contains { event in
                let p = URL(fileURLWithPath: event.path).resolvingSymlinksInPath().path
                return p == targetPath
            }
            if hit {
                DispatchQueue.main.async {
                    self.loadFileContent()
                }
            }
        }
        watcher.start()
        self.fileWatcher = watcher
    }
}
