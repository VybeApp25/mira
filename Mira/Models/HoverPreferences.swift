import Foundation

// MARK: - Per-category stats

struct CategoryStats: Codable {
    var shown: Int = 0
    var explained: Int = 0

    /// Returns 0.0–1.0. Neutral (0.5) until at least 4 data points.
    var engagementScore: Double {
        guard shown >= 4 else { return 0.5 }
        return Double(explained) / Double(shown)
    }
}

// MARK: - Preference store

/// Lightweight UserDefaults-backed profile of what content the user engages with.
/// Recorded automatically by HoverSummaryService; read back to personalise the
/// interesting-flag prompt so the threshold adapts over time.
final class HoverPreferences {

    static let shared = HoverPreferences()

    private(set) var categories: [String: CategoryStats] = [:]
    private let udKey = "mira_hover_prefs_v1"

    private init() { load() }

    // MARK: - Recording

    func recordShown(category: String) {
        categories[category, default: CategoryStats()].shown += 1
        save()
    }

    func recordExplained(category: String) {
        categories[category, default: CategoryStats()].explained += 1
        save()
    }

    // MARK: - Context injection

    /// One-line hint injected into the Claude system prompt so it can personalise
    /// the interesting flag. Empty string when there isn't enough data yet.
    func contextHint() -> String {
        let mature = categories.filter { $0.value.shown >= 4 }
        guard !mature.isEmpty else { return "" }

        let high = mature.filter { $0.value.engagementScore > 0.60 }
                         .sorted { $0.value.engagementScore > $1.value.engagementScore }
                         .map(\.key)
        let low  = mature.filter { $0.value.engagementScore < 0.20 }
                         .sorted { $0.value.engagementScore < $1.value.engagementScore }
                         .map(\.key)

        var parts: [String] = []
        if !high.isEmpty {
            parts.append("User frequently explores: \(high.joined(separator: ", ")) — lean toward interesting=true for these.")
        }
        if !low.isEmpty {
            parts.append("User rarely engages with: \(low.joined(separator: ", ")) — set interesting=false unless the content is very prominent.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([String: CategoryStats].self, from: data) else { return }
        categories = decoded
    }
}
