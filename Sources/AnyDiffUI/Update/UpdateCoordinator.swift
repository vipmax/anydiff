import AppKit
import AnyDiffCore

/// Owns the update check state shared by the app menu and the main toolbar.
@MainActor
public final class UpdateCoordinator: ObservableObject {
    public static let shared = UpdateCoordinator()

    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case installing(UpdateInfo)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    private static let automaticChecksKey = "anydiff_automatic_update_checks"
    private static let knownUpdateKey = "anydiff_known_update"

    private let checker: UpdateChecker
    private let defaults: UserDefaults
    private var scheduledChecks: Task<Void, Never>?

    public init(checker: UpdateChecker = UpdateChecker(), defaults: UserDefaults = .standard) {
        self.checker = checker
        self.defaults = defaults
        // Restore the last known update so the toolbar button survives relaunches between checks.
        if let data = defaults.data(forKey: Self.knownUpdateKey),
           let info = try? JSONDecoder().decode(UpdateInfo.self, from: data),
           info.version > currentVersion {
            state = .available(info)
        }
    }

    /// The newer release the toolbar and menu offer, including one that is being installed.
    public var pendingUpdate: UpdateInfo? {
        switch state {
        case .available(let info), .installing(let info):
            return info
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    public var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    public var automaticChecksEnabled: Bool {
        defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    /// Turns automatic checks on or off. Turning them on starts the schedule right away.
    public func setAutomaticChecksEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticChecksKey)
        if enabled {
            startScheduledChecks()
        } else {
            stopScheduledChecks()
        }
    }

    /// Version from the bundle's Info.plist. Builds without one (e.g. `just dev`) count as 0.0.0,
    /// so every published release is newer than them.
    public var currentVersion: SemanticVersion {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(SemanticVersion.init) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    /// Checks now, then at the top of every hour. No-op when automatic checks are off or already running.
    public func startScheduledChecks() {
        guard automaticChecksEnabled, scheduledChecks == nil else { return }
        scheduledChecks = Task { await runScheduledChecks() }
    }

    public func stopScheduledChecks() {
        scheduledChecks?.cancel()
        scheduledChecks = nil
    }

    private func runScheduledChecks() async {
        await check(userInitiated: false)
        while true {
            let delay = UpdateSchedule.nextHourlyCheck(after: Date()).timeIntervalSinceNow
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return // Cancelled: automatic checks were turned off.
            }
            await check(userInitiated: false)
        }
    }

    /// Fetches the latest release. Failures are reported only for user-initiated checks.
    public func check(userInitiated: Bool) async {
        // Installing replaces the app and restarts it, so a concurrent check must not overwrite that state.
        guard !isInstalling else { return }
        let current = currentVersion
        let previous = state
        // Only a user-initiated check shows "checking"; a silent check must not hide a known update.
        if userInitiated { state = .checking }
        do {
            if let info = try await checker.latestUpdate(newerThan: current) {
                state = .available(info)
                if let data = try? JSONEncoder().encode(info) {
                    defaults.set(data, forKey: Self.knownUpdateKey)
                }
            } else {
                state = .upToDate
                defaults.removeObject(forKey: Self.knownUpdateKey)
            }
        } catch {
            state = userInitiated ? .failed(error.localizedDescription) : previous
        }
    }

    public func openReleasePage() {
        guard let info = pendingUpdate else { return }
        NSWorkspace.shared.open(info.releaseURL)
    }

    /// Asks the user, then installs the pending update and restarts AnyDiff.
    /// Builds that are not an `.app` bundle (e.g. `just dev`) cannot replace themselves, so they get the release page.
    public func confirmAndInstall() {
        guard let info = pendingUpdate, !isInstalling else { return }
        let canInstall = Bundle.main.bundleURL.pathExtension == "app"

        let alert = NSAlert()
        alert.messageText = "Update AnyDiff to \(info.version)?"
        if canInstall {
            alert.informativeText = "AnyDiff will restart to finish the update."
            alert.addButton(withTitle: "Update and Restart")
        } else {
            alert.informativeText = "This build cannot update itself. Download the release from GitHub instead."
            alert.addButton(withTitle: "Open Release Page")
        }
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if canInstall {
            Task { await install(info) }
        } else {
            openReleasePage()
        }
    }

    /// Upgrades through Homebrew when the cask installed AnyDiff, otherwise downloads the release.
    /// On success the helper process swaps or reopens the app and this process terminates.
    private func install(_ info: UpdateInfo) async {
        state = .installing(info)
        let bundleURL = Bundle.main.bundleURL
        var stagingDirectory: URL?
        do {
            let installer = UpdateInstaller()
            switch InstallMethod.detect(bundleURL: bundleURL) {
            case .homebrewCask(let brew):
                try await installer.upgradeWithHomebrew(brew: brew, to: info, appBundleURL: bundleURL)
            case .directDownload:
                stagingDirectory = try await installer.downloadRelease(info, replacing: bundleURL)
            }

            let helper = AppRelauncher.makeHelper(
                replacing: bundleURL,
                stagingDirectory: stagingDirectory,
                afterExitOf: ProcessInfo.processInfo.processIdentifier
            )
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            if let stagingDirectory {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
            state = .available(info)
            presentInstallFailure(error, for: info)
        }
    }

    private func presentInstallFailure(_ error: Error, for info: UpdateInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not update AnyDiff"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(info.releaseURL)
        }
    }
}
