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

    // Signed-in state for proxy mode: the proxy authorizes provider calls with
    // the user's Supabase JWT, so readiness == having a session, not a key.
    var isSignedIn: Bool { !SupabaseService.cachedAccessToken.isEmpty }

    // True when Mira can make provider calls. In proxy mode that means a signed-in
    // session (the real keys live server-side); in legacy mode it means a usable
    // embedded/user key.
    var hasKey: Bool {
        if MiraBackend.useProxy { return isSignedIn }
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

    /// Mirrors RealtimeVoiceService.state so the collapsed pill can react without
    /// owning the service. IslandChatView writes this via onChange(of: realtime.state).
    @Published var realtimeState: RealtimeState = .idle

    /// Short description of what the cursor is hovering over. Set by HoverInsightManager; auto-clears after 5 s.
    @Published var hoverSummary: String?

    var cursorColor: Color { DS.Colors.accent }

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
