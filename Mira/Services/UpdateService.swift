import Foundation
import Sparkle

/// Wraps Sparkle's updater so any view can trigger an update check
/// without needing to know about the controller's lifecycle.
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    private let controller: SPUStandardUpdaterController

    @Published var lastChecked: Date? = UserDefaults.standard.object(forKey: "mira_last_update_check") as? Date

    private init() {
        // startingUpdater: false prevents Sparkle from auto-running on init.
        // With placeholder SUPublicEDKey / SUFeedURL, startingUpdater:true shows
        // a blocking NSAlert that freezes the UI (looks like a crash).
        // The updater starts explicitly when the user presses Check for Updates.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        // Start the updater lazily on first explicit check
        try? controller.updater.start()
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
