import Foundation

public struct FileLinkTarget: Equatable, Sendable {
    public enum TargetType: Equatable, Sendable {
        case file(path: String, line: Int?, endLine: Int?)
        case directory(path: String)
        case web(url: URL)
        case custom(url: URL)
    }

    public let originalURL: URL
    public let targetType: TargetType

    public init(originalURL: URL, targetType: TargetType) {
        self.originalURL = originalURL
        self.targetType = targetType
    }
}

public enum FileLinkParser {
    public static func parse(url: URL, workingDirectory: String? = nil) -> FileLinkTarget {
        let scheme = url.scheme?.lowercased()

        if scheme == "http" || scheme == "https" {
            return FileLinkTarget(originalURL: url, targetType: .web(url: url))
        }

        if let scheme, scheme != "file" {
            return FileLinkTarget(originalURL: url, targetType: .custom(url: url))
        }

        let fragment = url.fragment
        let (fragmentLine, fragmentEndLine) = parseLineAnchor(fragment)

        var rawPath: String
        if scheme == "file" {
            let p = url.path
            if (p.isEmpty || p == "/") && url.host != nil {
                rawPath = url.host! + p
            } else {
                rawPath = p
            }
        } else {
            rawPath = url.path
            if rawPath.isEmpty {
                rawPath = url.absoluteString
            }
        }

        if let decoded = rawPath.removingPercentEncoding {
            rawPath = decoded
        }

        let (cleanedPath, suffixLine, suffixEndLine) = extractLineFromPathSuffix(rawPath)
        let line = fragmentLine ?? suffixLine
        let endLine = fragmentEndLine ?? suffixEndLine

        var resolvedPath = (cleanedPath as NSString).expandingTildeInPath
        if !resolvedPath.hasPrefix("/") {
            if let workingDirectory, !workingDirectory.isEmpty {
                resolvedPath = (workingDirectory as NSString).appendingPathComponent(resolvedPath)
            }
        }
        resolvedPath = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue {
            return FileLinkTarget(originalURL: url, targetType: .directory(path: resolvedPath))
        }

        return FileLinkTarget(
            originalURL: url,
            targetType: .file(path: resolvedPath, line: line, endLine: endLine)
        )
    }

    public static func parse(urlString: String, workingDirectory: String? = nil) -> FileLinkTarget? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let directURL = URL(string: trimmed), let scheme = directURL.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" || scheme == "file" {
                return parse(url: directURL, workingDirectory: workingDirectory)
            }
            if scheme.count >= 2 && !trimmed.hasPrefix("/") {
                return parse(url: directURL, workingDirectory: workingDirectory)
            }
        }

        // Relative or plain path without scheme
        let (pathPart, fragment) = splitPathAndFragment(trimmed)
        let (cleanedPath, suffixLine, suffixEndLine) = extractLineFromPathSuffix(pathPart)
        let (fragmentLine, fragmentEndLine) = parseLineAnchor(fragment)
        let line = fragmentLine ?? suffixLine
        let endLine = fragmentEndLine ?? suffixEndLine

        var resolvedPath = (cleanedPath as NSString).expandingTildeInPath
        if !resolvedPath.hasPrefix("/") {
            if let workingDirectory, !workingDirectory.isEmpty {
                resolvedPath = (workingDirectory as NSString).appendingPathComponent(resolvedPath)
            }
        }
        resolvedPath = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path

        let fileURL = URL(fileURLWithPath: resolvedPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), isDir.boolValue {
            return FileLinkTarget(originalURL: fileURL, targetType: .directory(path: resolvedPath))
        }

        return FileLinkTarget(
            originalURL: fileURL,
            targetType: .file(path: resolvedPath, line: line, endLine: endLine)
        )
    }

    private static func splitPathAndFragment(_ text: String) -> (path: String, fragment: String?) {
        guard let hashIndex = text.firstIndex(of: "#") else {
            return (text, nil)
        }
        let p = String(text[..<hashIndex])
        let f = String(text[text.index(after: hashIndex)...])
        return (p, f)
    }

    public static func parseLineAnchor(_ fragment: String?) -> (line: Int?, endLine: Int?) {
        guard let fragment = fragment?.trimmingCharacters(in: .whitespacesAndNewlines), !fragment.isEmpty else {
            return (nil, nil)
        }

        var cleaned = fragment
        let lower = cleaned.lowercased()

        if lower.hasPrefix("line") {
            cleaned = String(cleaned.dropFirst(4))
            if cleaned.hasPrefix("-") || cleaned.hasPrefix("_") {
                cleaned = String(cleaned.dropFirst())
            }
        } else if lower.hasPrefix("l") {
            let afterL = cleaned.dropFirst()
            if let firstChar = afterL.first, firstChar.isNumber {
                cleaned = String(afterL)
            } else {
                return (nil, nil)
            }
        }

        let separators = CharacterSet(charactersIn: "-,.:")
        let parts = cleaned.components(separatedBy: separators).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return (nil, nil) }

        func parsePart(_ str: String) -> Int? {
            var s = str
            if s.lowercased().hasPrefix("l") {
                s = String(s.dropFirst())
            }
            guard !s.isEmpty, s.allSatisfy({ $0.isNumber }) else { return nil }
            return Int(s)
        }

        if parts.count >= 2 {
            guard let start = parsePart(parts[0]), let end = parsePart(parts[1]) else {
                return (nil, nil)
            }
            return (start, end)
        } else if let line = parsePart(parts[0]) {
            return (line, nil)
        }

        return (nil, nil)
    }

    public static func extractLineFromPathSuffix(_ path: String) -> (cleanPath: String, line: Int?, endLine: Int?) {
        guard let lastColon = path.lastIndex(of: ":") else {
            return (path, nil, nil)
        }

        let suffix = String(path[path.index(after: lastColon)...])
        let remaining = String(path[..<lastColon])

        if let secondColon = remaining.lastIndex(of: ":") {
            let secondSuffix = String(remaining[remaining.index(after: secondColon)...])
            if let line1 = Int(secondSuffix), let _ = Int(suffix) {
                let clean = String(remaining[..<secondColon])
                return (clean, line1, nil)
            }
        }

        let (start, end) = parseLineAnchor(suffix)
        if start != nil {
            return (remaining, start, end)
        }

        return (path, nil, nil)
    }
}
