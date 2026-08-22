import Foundation

func initialPath(from arguments: [String]) -> String? {
    for argument in arguments.dropFirst() {
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "--" else { continue }

        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return value
        }

        let expandedPath = (value as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return expandedPath
        }
    }

    return nil
}
