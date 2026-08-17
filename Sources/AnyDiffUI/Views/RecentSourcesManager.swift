import Foundation
import Combine

public final class RecentSourcesManager: ObservableObject {
    public static let shared = RecentSourcesManager()

    private let localPathsKey = "AnyDiff_RecentLocalPaths"
    private let localCountsKey = "AnyDiff_RecentLocalOpenCounts"
    private let remoteURLsKey = "AnyDiff_RecentRemoteURLs"
    private let remoteCountsKey = "AnyDiff_RecentRemoteOpenCounts"
    private let dismissedPresetsKey = "AnyDiff_DismissedPresetURLs"
    private let maxItems = 30

    @Published public private(set) var recentLocalPaths: [String] = []
    @Published public private(set) var recentRemoteURLs: [String] = []
    @Published public private(set) var dismissedPresets: Set<String> = []

    private var localOpenCounts: [String: Int] = [:]
    private var remoteOpenCounts: [String: Int] = [:]

    private init() {
        loadRecents()
    }

    public func loadRecents() {
        if let counts = UserDefaults.standard.dictionary(forKey: localCountsKey) as? [String: Int] {
            self.localOpenCounts = counts
        }
        if let remoteCounts = UserDefaults.standard.dictionary(forKey: remoteCountsKey) as? [String: Int] {
            self.remoteOpenCounts = remoteCounts
        }

        if let paths = UserDefaults.standard.stringArray(forKey: localPathsKey) {
            let validPaths = paths.filter { FileManager.default.fileExists(atPath: $0) }
            self.recentLocalPaths = sortPathsByUsage(validPaths)
        }
        if let urls = UserDefaults.standard.stringArray(forKey: remoteURLsKey) {
            self.recentRemoteURLs = urls
        }
        if let dismissed = UserDefaults.standard.stringArray(forKey: dismissedPresetsKey) {
            self.dismissedPresets = Set(dismissed)
        }
    }

    private func sortPathsByUsage(_ paths: [String]) -> [String] {
        let orderMap = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($0.element, $0.offset) })
        return paths.sorted { p1, p2 in
            let c1 = localOpenCounts[p1] ?? 1
            let c2 = localOpenCounts[p2] ?? 1
            if c1 != c2 {
                return c1 > c2
            }
            return (orderMap[p1] ?? 0) < (orderMap[p2] ?? 0)
        }
    }

    public func addLocalPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let newCount = (localOpenCounts[trimmed] ?? 0) + 1
        localOpenCounts[trimmed] = newCount
        UserDefaults.standard.set(localOpenCounts, forKey: localCountsKey)

        var recencyList = recentLocalPaths.filter { $0 != trimmed }
        recencyList.insert(trimmed, at: 0)
        if recencyList.count > maxItems {
            recencyList = Array(recencyList.prefix(maxItems))
        }

        let sorted = sortPathsByUsage(recencyList)
        self.recentLocalPaths = sorted
        UserDefaults.standard.set(recencyList, forKey: localPathsKey)
    }

    public func removeLocalPath(_ path: String) {
        let list = recentLocalPaths.filter { $0 != path }
        self.recentLocalPaths = list
        localOpenCounts.removeValue(forKey: path)
        UserDefaults.standard.set(list, forKey: localPathsKey)
        UserDefaults.standard.set(localOpenCounts, forKey: localCountsKey)
    }

    public func addRemoteURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let newCount = (remoteOpenCounts[trimmed] ?? 0) + 1
        remoteOpenCounts[trimmed] = newCount
        UserDefaults.standard.set(remoteOpenCounts, forKey: remoteCountsKey)

        var list = recentRemoteURLs.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > maxItems {
            list = Array(list.prefix(maxItems))
        }

        self.recentRemoteURLs = list
        UserDefaults.standard.set(list, forKey: remoteURLsKey)
    }

    public func removeRemoteURL(_ url: String) {
        let list = recentRemoteURLs.filter { $0 != url }
        self.recentRemoteURLs = list
        remoteOpenCounts.removeValue(forKey: url)
        UserDefaults.standard.set(list, forKey: remoteURLsKey)
        UserDefaults.standard.set(remoteOpenCounts, forKey: remoteCountsKey)
    }

    public func dismissPreset(url: String) {
        dismissedPresets.insert(url)
        UserDefaults.standard.set(Array(dismissedPresets), forKey: dismissedPresetsKey)
    }

    public func isPresetDismissed(url: String) -> Bool {
        dismissedPresets.contains(url)
    }

    public func clearAll() {
        recentLocalPaths = []
        recentRemoteURLs = []
        dismissedPresets = []
        localOpenCounts = [:]
        remoteOpenCounts = [:]
        UserDefaults.standard.removeObject(forKey: localPathsKey)
        UserDefaults.standard.removeObject(forKey: localCountsKey)
        UserDefaults.standard.removeObject(forKey: remoteURLsKey)
        UserDefaults.standard.removeObject(forKey: remoteCountsKey)
        UserDefaults.standard.removeObject(forKey: dismissedPresetsKey)
    }
}
