import Foundation

// Lightweight PostHog client — HTTP capture only (no SDK dependency).
// All calls are fire-and-forget; analytics must never block the main thread.
@MainActor
final class PostHogService {
    static let shared = PostHogService()

    private let apiKey  = AppSecrets.postHogKey
    private let host    = AppSecrets.postHogHost
    private let session = URLSession(configuration: .ephemeral)

    private var distinctId: String {
        if let id = UserDefaults.standard.string(forKey: "mira_ph_distinct_id") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "mira_ph_distinct_id")
        return id
    }

    private init() {}

    /// User-facing analytics opt-out (Privacy Policy §6). Defaults to enabled;
    /// when off, NO analytics is sent — including `identify`/PII, since every call
    /// funnels through `send`.
    static var analyticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "mira_analytics_enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "mira_analytics_enabled") }
    }

    // MARK: - Public API

    func capture(_ event: String, properties: [String: String] = [:]) {
        var props = properties
        props["$os"] = "macOS"
        props["app"] = "Mira"
        send(event: event, properties: props)
    }

    func identify(userId: String, email: String?, name: String?) {
        var traits: [String: String] = [:]
        if let email { traits["email"] = email }
        if let name  { traits["name"]  = name  }
        send(event: "$identify", properties: ["$anon_distinct_id": distinctId,
                                               "distinct_id": userId] + traits)
        UserDefaults.standard.set(userId, forKey: "mira_ph_distinct_id")
    }

    func page(_ name: String, properties: [String: String] = [:]) {
        var props = properties
        props["$current_url"] = "mira://\(name)"
        capture("$pageview", properties: props)
    }

    // MARK: - Send

    private func send(event: String, properties: [String: String]) {
        guard Self.analyticsEnabled else { return }   // honor the analytics opt-out
        guard let url = URL(string: "\(host)/capture/") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "api_key":     apiKey,
            "distinct_id": distinctId,
            "event":       event,
            "properties":  properties,
            "timestamp":   ISO8601DateFormatter().string(from: Date())
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        req.httpBody = body

        let task = session.dataTask(with: req)
        task.resume()
    }
}

private func + (lhs: [String: String], rhs: [String: String]) -> [String: String] {
    var result = lhs; rhs.forEach { result[$0.key] = $0.value }; return result
}
