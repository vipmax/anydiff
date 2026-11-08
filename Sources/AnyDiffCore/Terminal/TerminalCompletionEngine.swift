import Foundation

/// Item presented in terminal command-line completion suggestions.
public struct TerminalCompletionItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        case file = "file"
        case directory = "directory"
        case command = "command"
        case subcommand = "subcommand"
        case flag = "flag"
        case gitBranch = "branch"
        case recipe = "recipe"
        case history = "history"
    }

    public let id: String
    public let label: String
    public let insertText: String
    public let kind: Kind
    public let detail: String?

    public init(
        id: String = UUID().uuidString,
        label: String,
        insertText: String,
        kind: Kind,
        detail: String? = nil
    ) {
        self.id = id
        self.label = label
        self.insertText = insertText
        self.kind = kind
        self.detail = detail
    }
}

/// Result of evaluating completions for the current command line and cursor.
public struct TerminalCompletionResult: Equatable {
    public let items: [TerminalCompletionItem]
    public let replaceRange: NSRange
    public let tokenPrefix: String

    public init(items: [TerminalCompletionItem], replaceRange: NSRange, tokenPrefix: String) {
        self.items = items
        self.replaceRange = replaceRange
        self.tokenPrefix = tokenPrefix
    }

    /// Longest common prefix among all completion candidates' insert text.
    public var longestCommonPrefix: String? {
        guard let first = items.first?.insertText, !first.isEmpty else { return nil }
        var common = first
        for item in items.dropFirst() {
            while !item.insertText.hasPrefix(common) && !common.isEmpty {
                common.removeLast()
            }
            if common.isEmpty { break }
        }
        return common.isEmpty ? nil : common
    }
}

/// Fast, UI-independent completion engine for the terminal command input bar.
public final class TerminalCompletionEngine: Sendable {
    public static let shared = TerminalCompletionEngine()

    /// Maximum number of suggestions to return and display at once.
    public static let maxSuggestions: Int = 5

    public init() {}

    private static let commonCommands: [(command: String, detail: String)] = [
        ("git", "Fast distributed version control system"),
        ("swift", "Swift compiler and package manager"),
        ("just", "Handy command runner"),
        ("cargo", "Rust package manager"),
        ("npm", "Node package manager"),
        ("pnpm", "Fast, disk space efficient package manager"),
        ("yarn", "Fast, reliable dependency management"),
        ("bun", "Fast all-in-one JavaScript runtime"),
        ("node", "JavaScript runtime"),
        ("python3", "Python interpreter"),
        ("docker", "Pack, ship and run applications as containers"),
        ("docker-compose", "Multi-container Docker applications"),
        ("code", "Visual Studio Code editor"),
        ("cat", "Concatenate and print files"),
        ("ls", "List directory contents"),
        ("cd", "Change working directory"),
        ("pwd", "Print working directory"),
        ("mkdir", "Make directories"),
        ("rm", "Remove directory entries"),
        ("cp", "Copy files"),
        ("mv", "Move files"),
        ("touch", "Change file access and modification times"),
        ("grep", "File pattern searcher"),
        ("find", "Walk a file hierarchy"),
        ("curl", "Transfer data from or to a server"),
        ("open", "Open files and directories"),
        ("make", "Maintain directed dependencies"),
        ("brew", "macOS package manager"),
        ("tar", "Manipulate tape archives"),
        ("ps", "Process status"),
        ("kill", "Terminate or signal a process"),
        ("clear", "Clear terminal screen"),
        ("echo", "Write arguments to the standard output"),
        ("which", "Locate a program file in user's path"),
        ("chmod", "Change file modes or Access Control Lists")
    ]

    private static let gitSubcommands: [(subcommand: String, detail: String)] = [
        ("status", "Show the working tree status"),
        ("diff", "Show changes between commits, working tree, etc."),
        ("add", "Add file contents to the index"),
        ("commit", "Record changes to the repository"),
        ("push", "Update remote refs along with associated objects"),
        ("pull", "Fetch from and integrate with another repository"),
        ("checkout", "Switch branches or restore working tree files"),
        ("switch", "Switch branches"),
        ("branch", "List, create, or delete branches"),
        ("fetch", "Download objects and refs from another repository"),
        ("merge", "Join two or more development histories together"),
        ("rebase", "Reapply commits on top of another base tip"),
        ("log", "Show commit logs"),
        ("stash", "Stash changes in a dirty working directory"),
        ("reset", "Reset current HEAD to the specified state"),
        ("restore", "Restore working tree files"),
        ("clone", "Clone a repository into a new directory"),
        ("show", "Show various types of objects"),
        ("tag", "Create, list, delete or verify a tag object"),
        ("cherry-pick", "Apply changes introduced by some existing commits"),
        ("remote", "Manage set of tracked repositories"),
        ("clean", "Remove untracked files from the working tree")
    ]

    private static let swiftSubcommands: [(subcommand: String, detail: String)] = [
        ("build", "Build sources into binary products"),
        ("test", "Build and run tests"),
        ("run", "Build and run an executable product"),
        ("package", "Perform operations on Swift packages")
    ]

    // MARK: - Public API

    /// Computes completions for the given input text, cursor location, and directory context.
    public func completions(
        text: String,
        cursorLocation: Int,
        currentDirectory: String,
        commandHistory: [String] = []
    ) -> TerminalCompletionResult {
        let safeLocation = max(0, min(cursorLocation, text.utf16.count))
        let (tokens, tokenIndex, replaceRange) = parseTokens(text: text, cursorLocation: safeLocation)
        let tokenPrefix = (text as NSString).substring(with: replaceRange)

        // Case 1: First token -> command completion
        if tokenIndex == 0 {
            let commandItems = completeCommand(
                prefix: tokenPrefix,
                currentDirectory: currentDirectory,
                commandHistory: commandHistory
            )
            return TerminalCompletionResult(items: Array(commandItems.prefix(Self.maxSuggestions)), replaceRange: replaceRange, tokenPrefix: tokenPrefix)
        }

        let commandWord = tokens.first ?? ""

        // Case 2: Git command
        if commandWord == "git" {
            if tokenIndex == 1 {
                let gitItems = completeGitSubcommand(prefix: tokenPrefix)
                return TerminalCompletionResult(items: Array(gitItems.prefix(Self.maxSuggestions)), replaceRange: replaceRange, tokenPrefix: tokenPrefix)
            } else if tokens.count > 1 {
                let branchItems = completeGitBranches(prefix: tokenPrefix, currentDirectory: currentDirectory)
                if !branchItems.isEmpty {
                    return TerminalCompletionResult(items: Array(branchItems.prefix(Self.maxSuggestions)), replaceRange: replaceRange, tokenPrefix: tokenPrefix)
                }
            }
        }

        // Case 3: Swift tool
        if commandWord == "swift" && tokenIndex == 1 {
            let swiftItems = completeSwiftSubcommand(prefix: tokenPrefix)
            if !swiftItems.isEmpty {
                return TerminalCompletionResult(items: Array(swiftItems.prefix(Self.maxSuggestions)), replaceRange: replaceRange, tokenPrefix: tokenPrefix)
            }
        }

        // Case 4: Just command runner
        if commandWord == "just" && tokenIndex == 1 {
            let justItems = completeJustRecipes(prefix: tokenPrefix, currentDirectory: currentDirectory)
            if !justItems.isEmpty {
                return TerminalCompletionResult(items: Array(justItems.prefix(Self.maxSuggestions)), replaceRange: replaceRange, tokenPrefix: tokenPrefix)
            }
        }

        // Case 5: npm run
        if (commandWord == "npm" || commandWord == "pnpm" || commandWord == "yarn") &&
           (tokenIndex == 1 || (tokens.count > 1 && tokens[1] == "run" && tokenIndex == 2)) {
            let scriptItems = completeNpmScripts(prefix: tokenPrefix, currentDirectory: currentDirectory)
            if !scriptItems.isEmpty {
                return TerminalCompletionResult(items: Array(scriptItems.prefix(Self.maxSuggestions)), replaceRange: replaceRange, tokenPrefix: tokenPrefix)
            }
        }

        // Case 6: Filesystem paths
        let isCd = (commandWord == "cd")
        let isPathArgument = tokenPrefix.hasPrefix("./") || tokenPrefix.hasPrefix("../") || tokenPrefix.hasPrefix("/") || tokenPrefix.hasPrefix("~")

        // 1. Verify commandWord is a valid binary in $PATH, a shell builtin, or a path
        let allCommands = Set(getSystemCommands())
        let isValidCommand = allCommands.contains(commandWord) || commandWord.contains("/")
        guard isValidCommand else {
            return TerminalCompletionResult(items: [], replaceRange: replaceRange, tokenPrefix: tokenPrefix)
        }

        // 2. If the user hasn't typed anything for this argument yet (empty prefix),
        // only show directory listing for `cd`. Do not pop up all files on space for arbitrary commands.
        if tokenPrefix.isEmpty && !isCd && !isPathArgument {
            return TerminalCompletionResult(items: [], replaceRange: replaceRange, tokenPrefix: tokenPrefix)
        }

        let fileItems = completeFilesystem(
            prefix: tokenPrefix,
            currentDirectory: currentDirectory,
            directoriesOnly: isCd
        )

        return TerminalCompletionResult(items: Array(fileItems.prefix(Self.maxSuggestions)), replaceRange: replaceRange, tokenPrefix: tokenPrefix)
    }

    // MARK: - Command Completion

    /// Dynamically discovered binaries from the user's $PATH, cached in memory.
    private static var cachedPathBinaries: [String]?
    private static let pathScanLock = NSLock()

    /// Discovers all available system executables across $PATH plus standard shell builtins.
    public func getSystemCommands() -> [String] {
        Self.pathScanLock.lock()
        defer { Self.pathScanLock.unlock() }

        if let cached = Self.cachedPathBinaries {
            return cached
        }

        var binaries = Set<String>()

        // 1. Standard shell builtins
        let builtins = [
            "cd", "pwd", "echo", "export", "alias", "unalias", "source", "type", "which",
            "history", "clear", "exit", "jobs", "fg", "bg", "read", "eval", "exec", "kill",
            "set", "unset", "true", "false", "test", "ulimit", "umask", "wait"
        ]
        binaries.formUnion(builtins)

        // 2. Scan directories from user's PATH environment
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        let dirs = pathEnv.split(separator: ":").map(String.init)
        let fm = FileManager.default

        for dir in dirs {
            let expanded = (dir as NSString).expandingTildeInPath
            if let entries = try? fm.contentsOfDirectory(atPath: expanded) {
                for entry in entries {
                    if !entry.hasPrefix(".") {
                        binaries.insert(entry)
                    }
                }
            }
        }

        let sorted = binaries.sorted()
        Self.cachedPathBinaries = sorted
        return sorted
    }

    // MARK: - Fuzzy & Substring Matching

    /// Matches a candidate string against a search query, returning a tier score where lower is better.
    public static func matchScore(candidate: String, query: String) -> Int? {
        if query.isEmpty { return 0 }
        let cLower = candidate.lowercased()
        let qLower = query.lowercased()
        if cLower == qLower {
            return 0
        }
        if cLower.hasPrefix(qLower) {
            return 1
        }
        let words = cLower.split { $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" }
        if words.contains(where: { $0.hasPrefix(qLower) }) {
            return 2
        }
        if cLower.contains(qLower) {
            return 3
        }
        // Subsequence / fuzzy match
        var qIdx = qLower.startIndex
        var dist = 0
        for ch in cLower {
            if qIdx < qLower.endIndex && ch == qLower[qIdx] {
                qIdx = qLower.index(after: qIdx)
            } else if qIdx > qLower.startIndex && qIdx < qLower.endIndex {
                dist += 1
            }
        }
        if qIdx == qLower.endIndex {
            return 4 + min(dist, 50)
        }
        return nil
    }

    private func completeCommand(
        prefix: String,
        currentDirectory: String,
        commandHistory: [String]
    ) -> [TerminalCompletionItem] {
        var scored: [(item: TerminalCompletionItem, score: Int)] = []
        var seen = Set<String>()

        let knownDetails: [String: String] = Dictionary(
            uniqueKeysWithValues: Self.commonCommands.map { ($0.command, $0.detail) }
        )

        // 1. Matches from user's actual $PATH binaries and shell builtins
        let allCommands = getSystemCommands()
        for cmd in allCommands {
            if let score = Self.matchScore(candidate: cmd, query: prefix) {
                if seen.insert(cmd).inserted {
                    let baseDetail = knownDetails[cmd] ?? "command"
                    let item = TerminalCompletionItem(
                        label: cmd,
                        insertText: cmd + " ",
                        kind: .command,
                        detail: baseDetail
                    )
                    scored.append((item, score))
                }
            }
        }

        // 2. Executables in current directory if starting with ./ or /
        if prefix.hasPrefix("./") || prefix.hasPrefix("/") {
            let fs = completeFilesystem(prefix: prefix, currentDirectory: currentDirectory, directoriesOnly: false)
            for item in fs {
                if seen.insert(item.insertText).inserted {
                    let score = Self.matchScore(candidate: item.label, query: prefix) ?? 1
                    scored.append((item, score))
                }
            }
        }

        // 3. Top history matches (unique command names)
        for hist in commandHistory.reversed() {
            let trimmed = hist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let firstWord = trimmed.components(separatedBy: .whitespaces).first ?? ""
            if !firstWord.isEmpty {
                if let score = Self.matchScore(candidate: firstWord, query: prefix) {
                    if seen.insert(firstWord).inserted {
                        let item = TerminalCompletionItem(
                            label: firstWord,
                            insertText: firstWord + " ",
                            kind: .history,
                            detail: "from history"
                        )
                        scored.append((item, max(0, score - 1)))
                    }
                }
            }
        }

        scored.sort { a, b in
            if a.score != b.score {
                return a.score < b.score
            }
            return a.item.label.localizedStandardCompare(b.item.label) == .orderedAscending
        }

        let minScore = scored.map(\.score).min() ?? 0
        let eligible = minScore <= 2 ? scored.filter { $0.score <= 2 } : scored
        return Array(eligible.prefix(Self.maxSuggestions).map(\.item))
    }

    // MARK: - Git Subcommands & Branches

    private func completeGitSubcommand(prefix: String) -> [TerminalCompletionItem] {
        var scored: [(sub: String, detail: String, score: Int)] = []
        for (sub, detail) in Self.gitSubcommands {
            if let score = Self.matchScore(candidate: sub, query: prefix) {
                scored.append((sub, detail, score))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.sub < $1.sub }
        let minScore = scored.map(\.score).min() ?? 0
        let eligible = minScore <= 2 ? scored.filter { $0.score <= 2 } : scored
        return eligible.map {
            TerminalCompletionItem(
                label: $0.sub,
                insertText: $0.sub + " ",
                kind: .subcommand,
                detail: $0.detail
            )
        }
    }

    private func completeGitBranches(prefix: String, currentDirectory: String) -> [TerminalCompletionItem] {
        var branches: [String] = []

        // Read .git/refs/heads directly for speed without spawning subprocesses
        let gitDir = (currentDirectory as NSString).appendingPathComponent(".git/refs/heads")
        let fm = FileManager.default
        if let enumerator = fm.enumerator(atPath: gitDir) {
            for case let file as String in enumerator {
                var isDir: ObjCBool = false
                let fullPath = (gitDir as NSString).appendingPathComponent(file)
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                    branches.append(file)
                }
            }
        }

        // Also check .git/packed-refs if heads is sparse
        let packedRefs = (currentDirectory as NSString).appendingPathComponent(".git/packed-refs")
        if let content = try? String(contentsOfFile: packedRefs, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                if line.hasPrefix("#") || line.hasPrefix("^") { continue }
                let parts = line.split(separator: " ")
                if parts.count >= 2 {
                    let ref = String(parts[1])
                    if ref.hasPrefix("refs/heads/") {
                        let name = String(ref.dropFirst("refs/heads/".count))
                        if !branches.contains(name) {
                            branches.append(name)
                        }
                    }
                }
            }
        }

        var scored: [(branch: String, score: Int)] = []
        for b in branches {
            if let score = Self.matchScore(candidate: b, query: prefix) {
                scored.append((b, score))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.branch < $1.branch }
        let minScore = scored.map(\.score).min() ?? 0
        let eligible = minScore <= 2 ? scored.filter { $0.score <= 2 } : scored
        return eligible.map {
            TerminalCompletionItem(
                label: $0.branch,
                insertText: $0.branch + " ",
                kind: .gitBranch,
                detail: "git branch"
            )
        }
    }

    // MARK: - Swift & Just & npm Recipes

    private func completeSwiftSubcommand(prefix: String) -> [TerminalCompletionItem] {
        var scored: [(sub: String, detail: String, score: Int)] = []
        for (sub, detail) in Self.swiftSubcommands {
            if let score = Self.matchScore(candidate: sub, query: prefix) {
                scored.append((sub, detail, score))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.sub < $1.sub }
        let minScore = scored.map(\.score).min() ?? 0
        let eligible = minScore <= 2 ? scored.filter { $0.score <= 2 } : scored
        return eligible.map {
            TerminalCompletionItem(
                label: $0.sub,
                insertText: $0.sub + " ",
                kind: .subcommand,
                detail: $0.detail
            )
        }
    }

    private func completeJustRecipes(prefix: String, currentDirectory: String) -> [TerminalCompletionItem] {
        let candidates = ["justfile", "Justfile", ".justfile"]
        for candidate in candidates {
            let path = (currentDirectory as NSString).appendingPathComponent(candidate)
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                var recipes: [String] = []
                for line in content.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
                    // Match `recipe_name:` or `recipe_name arg1 arg2:`
                    if let colonIdx = trimmed.firstIndex(of: ":") {
                        let beforeColon = trimmed[..<colonIdx].trimmingCharacters(in: .whitespaces)
                        let recipeName = String(beforeColon.split(separator: " ").first ?? "")
                        if !recipeName.isEmpty && !recipeName.contains("=") && !recipeName.hasPrefix("@") {
                            recipes.append(recipeName)
                        }
                    }
                }
                var scored: [(recipe: String, score: Int)] = []
                for r in recipes {
                    if let score = Self.matchScore(candidate: r, query: prefix) {
                        scored.append((r, score))
                    }
                }
                scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.recipe < $1.recipe }
                let minScore = scored.map(\.score).min() ?? 0
                let eligible = minScore <= 2 ? scored.filter { $0.score <= 2 } : scored
                return eligible.map {
                    TerminalCompletionItem(
                        label: $0.recipe,
                        insertText: $0.recipe + " ",
                        kind: .recipe,
                        detail: "just recipe"
                    )
                }
            }
        }
        return []
    }

    private func completeNpmScripts(prefix: String, currentDirectory: String) -> [TerminalCompletionItem] {
        let path = (currentDirectory as NSString).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else {
            return []
        }

        var scored: [(script: String, detail: String, score: Int)] = []
        for (script, val) in scripts {
            if let score = Self.matchScore(candidate: script, query: prefix) {
                let detail = (val as? String).map { String($0.prefix(40)) } ?? "npm script"
                scored.append((script, detail, score))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score < $1.score : $0.script < $1.script }
        let minScore = scored.map(\.score).min() ?? 0
        let eligible = minScore <= 2 ? scored.filter { $0.score <= 2 } : scored
        return eligible.map {
            TerminalCompletionItem(
                label: $0.script,
                insertText: $0.script + " ",
                kind: .recipe,
                detail: $0.detail
            )
        }
    }

    // MARK: - Filesystem Completion

    public struct ResolvedPathContext {
        public let searchDirectory: String
        public let filePart: String
        public let outputDirPrefix: String
    }

    /// Resolves path prefix into a directory to search, the filename/subpath filter, and the output display prefix.
    public func resolvePathContext(prefix: String, currentDirectory: String) -> ResolvedPathContext {
        let unescaped = unescapeShellPath(prefix)
        let home = NSHomeDirectory()

        if unescaped == "~" || unescaped == "~/" {
            return ResolvedPathContext(
                searchDirectory: home,
                filePart: "",
                outputDirPrefix: "~/"
            )
        }

        if unescaped.hasPrefix("~/") {
            let relativeToHome = String(unescaped.dropFirst(2))
            if unescaped.hasSuffix("/") {
                let fullDir = (home as NSString).appendingPathComponent(relativeToHome)
                return ResolvedPathContext(
                    searchDirectory: fullDir,
                    filePart: "",
                    outputDirPrefix: unescaped
                )
            } else if let lastSlash = relativeToHome.lastIndex(of: "/") {
                let dirSub = String(relativeToHome[..<lastSlash])
                let fileSub = String(relativeToHome[relativeToHome.index(after: lastSlash)...])
                let fullDir = (home as NSString).appendingPathComponent(dirSub)
                let outPrefix = "~/" + String(relativeToHome[...lastSlash])
                return ResolvedPathContext(
                    searchDirectory: fullDir,
                    filePart: fileSub,
                    outputDirPrefix: outPrefix
                )
            } else {
                return ResolvedPathContext(
                    searchDirectory: home,
                    filePart: relativeToHome,
                    outputDirPrefix: "~/"
                )
            }
        }

        if unescaped.hasPrefix("/") {
            if unescaped.hasSuffix("/") {
                return ResolvedPathContext(
                    searchDirectory: unescaped,
                    filePart: "",
                    outputDirPrefix: unescaped
                )
            } else if let lastSlash = unescaped.lastIndex(of: "/") {
                let dirSub = String(unescaped[...lastSlash])
                let fileSub = String(unescaped[unescaped.index(after: lastSlash)...])
                return ResolvedPathContext(
                    searchDirectory: dirSub,
                    filePart: fileSub,
                    outputDirPrefix: dirSub
                )
            } else {
                return ResolvedPathContext(
                    searchDirectory: "/",
                    filePart: String(unescaped.dropFirst()),
                    outputDirPrefix: "/"
                )
            }
        }

        if unescaped.isEmpty {
            return ResolvedPathContext(
                searchDirectory: currentDirectory,
                filePart: "",
                outputDirPrefix: ""
            )
        }

        if unescaped.hasSuffix("/") {
            let fullDir = (currentDirectory as NSString).appendingPathComponent(unescaped)
            return ResolvedPathContext(
                searchDirectory: fullDir,
                filePart: "",
                outputDirPrefix: unescaped
            )
        } else if let lastSlash = unescaped.lastIndex(of: "/") {
            let dirSub = String(unescaped[..<lastSlash])
            let fileSub = String(unescaped[unescaped.index(after: lastSlash)...])
            let fullDir = (currentDirectory as NSString).appendingPathComponent(dirSub)
            let outPrefix = String(unescaped[...lastSlash])
            return ResolvedPathContext(
                searchDirectory: fullDir,
                filePart: fileSub,
                outputDirPrefix: outPrefix
            )
        } else {
            return ResolvedPathContext(
                searchDirectory: currentDirectory,
                filePart: unescaped,
                outputDirPrefix: ""
            )
        }
    }

    private func completeFilesystem(
        prefix: String,
        currentDirectory: String,
        directoriesOnly: Bool
    ) -> [TerminalCompletionItem] {
        let fm = FileManager.default
        let ctx = resolvePathContext(prefix: prefix, currentDirectory: currentDirectory)

        guard let entries = try? fm.contentsOfDirectory(atPath: ctx.searchDirectory) else {
            return []
        }

        let showHidden = ctx.filePart.hasPrefix(".")

        struct ScoredEntry {
            let name: String
            let isDir: Bool
            let score: Int
        }

        var scored: [ScoredEntry] = []

        for entry in entries {
            if !showHidden && entry.hasPrefix(".") {
                continue
            }
            // File/directory completion requires prefix match (score 1) or word-boundary prefix (score 2)
            guard let score = Self.matchScore(candidate: entry, query: ctx.filePart), score <= 2 else {
                continue
            }

            let fullPath = (ctx.searchDirectory as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    scored.append(ScoredEntry(name: entry, isDir: true, score: score))
                } else if !directoriesOnly {
                    scored.append(ScoredEntry(name: entry, isDir: false, score: score))
                }
            }
        }

        scored.sort { a, b in
            if a.score != b.score {
                return a.score < b.score
            }
            if a.isDir != b.isDir {
                return a.isDir && !b.isDir
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }

        let eligible = scored

        var results: [TerminalCompletionItem] = []
        for item in eligible {
            let escaped = escapeShellPath(item.name)
            if item.isDir {
                let insertText = ctx.outputDirPrefix + escaped + "/"
                results.append(TerminalCompletionItem(
                    label: item.name + "/",
                    insertText: insertText,
                    kind: .directory,
                    detail: "folder"
                ))
            } else {
                let insertText = ctx.outputDirPrefix + escaped + (directoriesOnly ? "" : " ")
                results.append(TerminalCompletionItem(
                    label: item.name,
                    insertText: insertText,
                    kind: .file,
                    detail: "file"
                ))
            }
            if results.count >= Self.maxSuggestions { break }
        }

        return results
    }

    // MARK: - Path Escaping Helpers

    public func escapeShellPath(_ path: String) -> String {
        // Escapes characters like spaces, parens, brackets, etc.
        var escaped = ""
        for char in path {
            switch char {
            case " ", "(", ")", "[", "]", "{", "}", "&", ";", "$", "\"", "'", "*", "?", "!", "\\":
                escaped.append("\\")
                escaped.append(char)
            default:
                escaped.append(char)
            }
        }
        return escaped
    }

    public func unescapeShellPath(_ path: String) -> String {
        var unescaped = ""
        var isEscaped = false
        for char in path {
            if isEscaped {
                unescaped.append(char)
                isEscaped = false
            } else if char == "\\" {
                isEscaped = true
            } else {
                unescaped.append(char)
            }
        }
        return unescaped
    }

    // MARK: - Tokenizer

    /// Tokenizes command line up to cursor, identifying the token under cursor and its range.
    public func parseTokens(text: String, cursorLocation: Int) -> (tokens: [String], tokenIndex: Int, replaceRange: NSRange) {
        let ns = text as NSString
        let clamped = max(0, min(cursorLocation, ns.length))
        let prefixText = ns.substring(to: clamped)

        // Find current command segment separated by ; | && ||
        let segmentSeparators = [";", "&&", "||", "|"]
        var segmentStart = 0
        for sep in segmentSeparators {
            var searchRange = NSRange(location: 0, length: clamped)
            while true {
                let found = (prefixText as NSString).range(of: sep, options: [], range: searchRange)
                if found.location == NSNotFound { break }
                let after = found.location + found.length
                if after > segmentStart && after <= clamped {
                    segmentStart = after
                }
                let nextLoc = found.location + 1
                if nextLoc < clamped {
                    searchRange = NSRange(location: nextLoc, length: clamped - nextLoc)
                } else {
                    break
                }
            }
        }

        let segment = (prefixText as NSString).substring(from: segmentStart)
        let segmentOffset = segmentStart

        // Parse tokens within the segment
        var tokens: [String] = []
        var currentToken = ""
        var tokenStartInSegment = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        var isEscaped = false

        var tokenRanges: [NSRange] = []

        let segChars = Array(segment)
        for i in 0..<segChars.count {
            let char = segChars[i]

            if isEscaped {
                currentToken.append(char)
                isEscaped = false
                continue
            }

            if char == "\\" && !inSingleQuote {
                isEscaped = true
                continue
            }

            if char == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
                continue
            }

            if char == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
                continue
            }

            if char.isWhitespace && !inSingleQuote && !inDoubleQuote {
                if !currentToken.isEmpty {
                    tokens.append(currentToken)
                    tokenRanges.append(NSRange(location: segmentOffset + tokenStartInSegment, length: i - tokenStartInSegment))
                    currentToken = ""
                }
                tokenStartInSegment = i + 1
            } else {
                if currentToken.isEmpty {
                    tokenStartInSegment = i
                }
                currentToken.append(char)
            }
        }

        // If cursor is at trailing whitespace:
        if segment.hasSuffix(" ") || segment.isEmpty {
            let tokenIndex = tokens.count
            let replaceRange = NSRange(location: clamped, length: 0)
            return (tokens, tokenIndex, replaceRange)
        } else {
            tokens.append(currentToken)
            let len = segChars.count - tokenStartInSegment
            let replaceRange = NSRange(location: segmentOffset + tokenStartInSegment, length: len)
            let tokenIndex = tokens.count - 1
            return (tokens, tokenIndex, replaceRange)
        }
    }
}
