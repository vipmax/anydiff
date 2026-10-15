import AppKit
import Combine
import AnyDiffCore
import AnyDiffUI

extension AppDelegate {
    @MainActor
    func observeUpdateState() {
        updateStateObservation = UpdateCoordinator.shared.$state
            .sink { [weak self] state in
                self?.checkForUpdatesItem?.title = Self.checkForUpdatesTitle(for: state)
            }
    }

    private static func checkForUpdatesTitle(for state: UpdateCoordinator.State) -> String {
        switch state {
        case .checking:
            return "Checking for Updates…"
        case .available(let info):
            return "Update AnyDiff to \(info.version)…"
        case .installing:
            return "Updating AnyDiff…"
        case .idle, .upToDate, .failed:
            return "Check for Updates…"
        }
    }

    @MainActor
    @objc func checkForUpdatesAction(_ sender: Any?) {
        let updates = UpdateCoordinator.shared
        if updates.pendingUpdate != nil {
            updates.confirmAndInstall()
            return
        }
        guard updates.state != .checking else { return }
        Task { @MainActor in
            await updates.check(userInitiated: true)
            if updates.pendingUpdate != nil {
                updates.confirmAndInstall()
            } else {
                presentUpdateResult(updates.state)
            }
        }
    }

    @MainActor
    @objc func toggleAutomaticUpdateChecksAction(_ sender: NSMenuItem) {
        let updates = UpdateCoordinator.shared
        updates.setAutomaticChecksEnabled(!updates.automaticChecksEnabled)
        sender.state = updates.automaticChecksEnabled ? .on : .off
    }

    @MainActor
    private func presentUpdateResult(_ state: UpdateCoordinator.State) {
        let alert = NSAlert()
        switch state {
        case .upToDate:
            alert.messageText = "AnyDiff is up to date"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Could not check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .idle, .checking, .available, .installing:
            break
        }
    }
}
