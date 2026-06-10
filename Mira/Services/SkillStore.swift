import Foundation

// Persists which Mira skills are toggled on and assembles the
// context block injected into Claude's system prompt.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    // Thread-safe cache so MiraPrompts.system (nonisolated) can read it.
    nonisolated(unsafe) static var cachedContext: String = ""

    let all: [MiraSkill] = MiraSkillCatalog.all
    @Published private(set) var activeIDs: Set<String>

    private let defaultsKey = "mira_active_skill_ids"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        activeIDs = Set(saved)
        Self.cachedContext = Self.buildContext(ids: activeIDs, all: MiraSkillCatalog.all)
    }

    func toggle(_ id: String) {
        let willActivate = !activeIDs.contains(id)
        if willActivate { activeIDs.insert(id) } else { activeIDs.remove(id) }
        UserDefaults.standard.set(Array(activeIDs), forKey: defaultsKey)
        Self.cachedContext = Self.buildContext(ids: activeIDs, all: all)
        AudioCueService.shared.play(willActivate ? .skillUp : .skillDown)
    }

    func isActive(_ id: String) -> Bool { activeIDs.contains(id) }

    private static func buildContext(ids: Set<String>, all: [MiraSkill]) -> String {
        let active = all.filter { ids.contains($0.id) }
        guard !active.isEmpty else { return "" }
        return "\n\n" + active.map(\.context).joined(separator: "\n\n")
    }
}
