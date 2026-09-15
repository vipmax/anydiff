import SwiftUI
import AppKit
import AnyDiffCore

/// Represents a single node in the project file tree.
public struct FileItem: Identifiable, Hashable, Sendable {
    public let id: String // full absolute path
    public let name: String
    public let relativePath: String
    public let fullPath: String
    public let isDirectory: Bool
    public var level: Int

    public init(
        name: String,
        relativePath: String,
        fullPath: String,
        isDirectory: Bool,
        level: Int = 0
    ) {
        self.id = fullPath
        self.name = name
        self.relativePath = relativePath
        self.fullPath = fullPath
        self.isDirectory = isDirectory
        self.level = level
    }
}

public struct FilesPanelView: View {
    public var rootDirectory: String
    public var fileDiffs: [FileDiff]
    public var openFilePaths: Set<String>
    public var theme: Theme
    @Binding public var selectedFilePath: String?
    public var onOpenFile: (String) -> Void
    public var onOpenExternalIDE: ((String) -> Void)?
    public var onBack: (() -> Void)?
    public var onSwitchToChanges: (() -> Void)?

    @State private var expandedPaths: Set<String> = []
    @State private var folderChildrenCache: [String: [FileItem]] = [:]
    @State private var rootItems: [FileItem] = []
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @FocusState private var isSearchFocused: Bool
    @State private var isTitleHovered: Bool = false

    public init(
        rootDirectory: String,
        fileDiffs: [FileDiff],
        openFilePaths: Set<String> = [],
        theme: Theme,
        selectedFilePath: Binding<String?>,
        onOpenFile: @escaping (String) -> Void,
        onOpenExternalIDE: ((String) -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        onSwitchToChanges: (() -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.fileDiffs = fileDiffs
        self.openFilePaths = openFilePaths
        self.theme = theme
        self._selectedFilePath = selectedFilePath
        self.onOpenFile = onOpenFile
        self.onOpenExternalIDE = onOpenExternalIDE
        self.onBack = onBack
        self.onSwitchToChanges = onSwitchToChanges
        self._expandedPaths = State(initialValue: rootDirectory.isEmpty ? [] : [rootDirectory])
    }

    private var gitStatusMap: [String: FileDiffStatus] {
        var map = [String: FileDiffStatus]()
        for diff in fileDiffs {
            map[diff.displayPath] = diff.status
        }
        return map
    }

    private var visibleItems: [FileItem] {
        if !searchText.isEmpty {
            return flatSearchMatches()
        }

        var result: [FileItem] = []
        func appendChildren(of items: [FileItem]) {
            for item in items {
                result.append(item)
                if item.isDirectory && expandedPaths.contains(item.fullPath) {
                    let children = getOrLoadChildren(for: item.fullPath, level: item.level + 1)
                    appendChildren(of: children)
                }
            }
        }
        appendChildren(of: rootItems)
        return result
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { headerGeo in
                PanelHeaderView(
                    theme: theme,
                    onBack: onBack
                ) {
                    headerLeadingView(availableWidth: headerGeo.size.width)
                } actions: {
                    headerTrailingActions(availableWidth: headerGeo.size.width)
                }
                .frame(width: headerGeo.size.width, height: 28, alignment: .leading)
            }
            .frame(height: 28)

            if isSearchVisible {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            treeArea
        }
        .background(Color(theme.background).ignoresSafeArea())
        .onAppear {
            reloadRoot()
        }
        .onChange(of: rootDirectory) { newRoot in
            folderChildrenCache.removeAll()
            expandedPaths.removeAll()
            expandedPaths.insert(newRoot)
            reloadRoot(for: newRoot)
        }
    }

    // MARK: - Header Views

    @ViewBuilder
    private func headerLeadingView(availableWidth: CGFloat) -> some View {
        HStack(spacing: 5) {
            if let onSwitch = onSwitchToChanges {
                Button(action: onSwitch) {
                    Text("FILES")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Color(theme.foreground))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isTitleHovered ? Color(theme.gutterForeground).opacity(0.14) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isTitleHovered = hovering
                }
                .help("Switch to Git Changes (Cmd+1)")
            } else {
                Text("FILES")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(Color(theme.foreground))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .lineLimit(1)
                    .fixedSize()
            }

            let folderName = (rootDirectory as NSString).lastPathComponent
            if !folderName.isEmpty && availableWidth >= 200 {
                Text(folderName)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }

    @ViewBuilder
    private func headerTrailingActions(availableWidth: CGFloat) -> some View {
        HStack(spacing: 4) {
            // Collapse All Button (leftmost in trailing actions)
            if !expandedPaths.isEmpty {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expandedPaths.count > 1 || !expandedPaths.contains(rootDirectory) {
                            expandedPaths = [rootDirectory]
                        } else {
                            expandedPaths.removeAll()
                        }
                    }
                }) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(theme.gutterForeground))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(ToolbarHoverButtonStyle())
                .help("Collapse All Folders")
            }

            // Refresh Button (middle)
            Button(action: {
                folderChildrenCache.removeAll()
                reloadRoot()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(theme.gutterForeground))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help("Reload File Tree")

            // Search / Filter Button (rightmost)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSearchVisible.toggle()
                    if isSearchVisible {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            isSearchFocused = true
                        }
                    } else {
                        searchText = ""
                        isSearchFocused = false
                    }
                }
            }) {
                Image(systemName: isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSearchVisible ? Color.accentColor : Color(theme.gutterForeground))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(ToolbarHoverButtonStyle())
            .help("Filter files (Cmd+F)")
        }
    }

    // MARK: - Search Field

    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Color(theme.gutterForeground))
                .font(.system(size: 11))
            TextField("Filter files...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color(theme.foreground))
                .focused($isSearchFocused)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Color(theme.gutterForeground))
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(theme.gutterBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color(theme.gutterForeground).opacity(0.18)),
            alignment: .bottom
        )
    }

    // MARK: - Tree List

    @ViewBuilder
    private var treeArea: some View {
        if visibleItems.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(Color(theme.gutterForeground).opacity(0.5))
                Text(searchText.isEmpty ? "Empty directory" : "No matching files")
                    .font(.system(size: 12))
                    .foregroundColor(Color(theme.gutterForeground))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VirtualizedFileTreeView(
                items: visibleItems,
                expandedPaths: expandedPaths,
                gitStatusMap: gitStatusMap,
                openFilePaths: openFilePaths,
                theme: theme,
                selectedFilePath: $selectedFilePath,
                onToggleExpand: { path in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedPaths.contains(path) {
                            expandedPaths.remove(path)
                        } else {
                            expandedPaths.insert(path)
                        }
                    }
                },
                onOpenFile: { path in
                    selectedFilePath = path
                    onOpenFile(path)
                },
                onOpenExternalIDE: onOpenExternalIDE
            )
            .background(Color(theme.background))
        }
    }

    private func reloadRoot(for dir: String? = nil) {
        let targetDir = dir ?? rootDirectory
        guard !targetDir.isEmpty, FileManager.default.fileExists(atPath: targetDir) else {
            rootItems = []
            return
        }
        let rootName = (targetDir as NSString).lastPathComponent
        let rootItem = FileItem(
            name: rootName.isEmpty ? targetDir : rootName,
            relativePath: "",
            fullPath: targetDir,
            isDirectory: true,
            level: 0
        )
        rootItems = [rootItem]
        if !expandedPaths.contains(targetDir) {
            expandedPaths.insert(targetDir)
        }
    }

    private func getOrLoadChildren(for fullPath: String, level: Int) -> [FileItem] {
        if let cached = folderChildrenCache[fullPath] {
            return cached
        }
        let children = loadDirectoryChildren(for: fullPath, rootDir: rootDirectory, level: level)
        folderChildrenCache[fullPath] = children
        return children
    }

    private func loadDirectoryChildren(for fullPath: String, rootDir: String? = nil, level: Int) -> [FileItem] {
        let baseRoot = rootDir ?? rootDirectory
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: fullPath) else { return [] }

        var items: [FileItem] = []
        for name in names {
            if name.hasPrefix(".") && name != ".gitignore" && name != ".env" { continue }
            if ProjectSearchEngine.defaultIgnoredDirectories.contains(name) { continue }

            let itemFullPath = (fullPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: itemFullPath, isDirectory: &isDir) else { continue }

            let relPath: String
            if itemFullPath.hasPrefix(baseRoot) {
                relPath = String(itemFullPath.dropFirst(baseRoot.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                relPath = name
            }

            items.append(FileItem(
                name: name,
                relativePath: relPath,
                fullPath: itemFullPath,
                isDirectory: isDir.boolValue,
                level: level
            ))
        }

        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory && !b.isDirectory
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func flatSearchMatches() -> [FileItem] {
        guard !searchText.isEmpty else { return [] }
        var matches: [FileItem] = []
        let query = searchText.lowercased()

        func searchDir(path: String) {
            let children = getOrLoadChildren(for: path, level: 0)
            for child in children {
                if child.name.lowercased().contains(query) || child.relativePath.lowercased().contains(query) {
                    matches.append(child)
                }
                if child.isDirectory && matches.count < 150 {
                    searchDir(path: child.fullPath)
                }
            }
        }

        searchDir(path: rootDirectory)
        return matches
    }
}
