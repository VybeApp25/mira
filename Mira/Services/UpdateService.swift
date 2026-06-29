import Foundation
import Sparkle
import AppKit

/// Sparkle's standard user driver shows its UI two ways: modal NSAlerts (e.g.
/// "You're up to date") and a non-modal window (the "Update available" sheet
/// with release notes + Install). Two problems arise because Mira runs as an
/// LSUIElement agent app with `.accessory` activation policy and a notch overlay
/// pinned far above normal windows:
///
///  1. Modal alerts never receive focus, so `-[NSApplication runModalForWindow:]`
///     blocks the main thread forever waiting for a dismissal the user can't
///     perform — freezing the app.
///  2. The non-modal update window opens at the normal window level, *behind*
///     Mira's island panel (statusBar+10), so it's hidden under the notch and
///     can't be seen or clicked.
///
/// Bracket the entire update session: switch to `.regular` + activate so the UI
/// takes focus, and post `.miraSuspendForModal` so the island steps below normal
/// windows. Restore on session finish. The lifecycle hooks below cover both the
/// modal and non-modal paths.
final class UpdaterUIDelegate: NSObject, SPUStandardUserDriverDelegate {
    // Non-modal "Update available" window is about to be shown.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        beginUpdateUI()
    }

    // Modal alert ("up to date" / error) is about to be shown.
    func standardUserDriverWillShowModalAlert() {
        beginUpdateUI()
    }

    // The whole update session is wrapping up — restore the island + activation.
    func standardUserDriverWillFinishUpdateSession() {
        endUpdateUI()
    }

    private func beginUpdateUI() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .miraSuspendForModal, object: nil)
    }

    private func endUpdateUI() {
        NotificationCenter.default.post(name: .miraResumeFromModal, object: nil)
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Wraps Sparkle's updater so any view can trigger an update check
/// without needing to know about the controller's lifecycle.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    private let controller: SPUStandardUpdaterController
    private let uiDelegate = UpdaterUIDelegate()

    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: "mira_last_update_check") as? Date

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: uiDelegate
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked, forKey: "mira_last_update_check")
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var lastCheckedString: String {
        guard let date = lastChecked else { return "Never checked" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}
