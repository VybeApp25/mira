import Foundation
import SwiftUI
import Combine

class MiraState: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var dailyUsageCount: Int = 0

    static let freeLimit = 10

    // Key the user typed in Settings (optional override).
    var userAPIKey: String {
        get { UserDefaults.standard.string(forKey: "mira_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mira_api_key") }
    }

    // The key actually used for requests: user override first, then bundled key.
    var effectiveAPIKey: String {
        let user = userAPIKey
        if !user.isEmpty { return user }
        return AppSecrets.anthropicAPIKey
    }

    // True when a real key is available (bundled key counts, placeholder doesn't).
    var hasKey: Bool {
        let key = effectiveAPIKey
        return !key.isEmpty && !key.hasPrefix("PASTE_")
    }

    // When using the bundled key there's no per-user limit.
    var usingBundledKey: Bool {
        userAPIKey.isEmpty && hasKey
    }

    var isPro: Bool {
        UserDefaults.standard.bool(forKey: "mira_is_pro")
    }

    var canUse: Bool {
        hasKey && (usingBundledKey || isPro || dailyUsageCount < MiraState.freeLimit)
    }

    var cursorColor: Color { Color(red: 0.29, green: 0.62, blue: 1.0) }

    // Connected Composio apps
    var connectedApps: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mira_connected_apps") ?? []) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(Array(newValue), forKey: "mira_connected_apps")
        }
    }

    init() { loadDailyUsage() }

    func recordUsage() {
        guard !usingBundledKey else { return }   // don't count against limit for bundled key
        dailyUsageCount += 1
        UserDefaults.standard.set(dailyUsageCount, forKey: "mira_usage_count")
        UserDefaults.standard.set(Calendar.current.startOfDay(for: Date()), forKey: "mira_usage_date")
    }

    private func loadDailyUsage() {
        let savedDate = UserDefaults.standard.object(forKey: "mira_usage_date") as? Date ?? .distantPast
        if Calendar.current.isDateInToday(savedDate) {
            dailyUsageCount = UserDefaults.standard.integer(forKey: "mira_usage_count")
        }
    }
}
