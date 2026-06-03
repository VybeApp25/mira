import Foundation
import SwiftUI
import Combine

class MiraState: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var dailyUsageCount: Int = 0

    static let freeLimit = 10

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "mira_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mira_api_key") }
    }

    var isPro: Bool {
        UserDefaults.standard.bool(forKey: "mira_is_pro")
    }

    var canUse: Bool {
        !apiKey.isEmpty && (isPro || dailyUsageCount < MiraState.freeLimit)
    }

    // Cursor color for the screen pointer overlay
    var cursorColorName: String {
        get { UserDefaults.standard.string(forKey: "mira_cursor_color") ?? "Blue" }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: "mira_cursor_color")
        }
    }

    var cursorColor: Color {
        cursorColorOptions.first(where: { $0.name == cursorColorName })?.color
            ?? Color(red: 0.29, green: 0.62, blue: 1.0)
    }

    // Connected Composio apps
    var connectedApps: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: "mira_connected_apps") ?? []
            return Set(arr)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(Array(newValue), forKey: "mira_connected_apps")
        }
    }

    init() { loadDailyUsage() }

    func recordUsage() {
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
