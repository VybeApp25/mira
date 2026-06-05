import Foundation

struct HoverEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let reason: String?
    let appName: String?
    let timestamp: Date

    init(text: String, reason: String?, appName: String?) {
        self.id        = UUID()
        self.text      = text
        self.reason    = reason
        self.appName   = appName
        self.timestamp = Date()
    }
}

final class HoverHistoryStore: ObservableObject {
    static let shared = HoverHistoryStore()

    private let udKey    = "mira_hover_history_v1"
    private let maxCount = 20

    @Published private(set) var entries: [HoverEntry] = []

    private init() { load() }

    func record(_ entry: HoverEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxCount { entries = Array(entries.prefix(maxCount)) }
        save()
    }

    func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: udKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: udKey),
              let decoded = try? JSONDecoder().decode([HoverEntry].self, from: data) else { return }
        entries = decoded
    }
}
