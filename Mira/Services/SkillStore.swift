import Foundation

// Persists which Mira skills are toggled on and assembles the
// context block injected into Claude's system prompt.
@MainActor
final class SkillStore: ObservableObject {
    static let shared = SkillStore()

    // Thread-safe cache so MiraPrompts.system (nonisolated) can read it.
    nonisolated(unsafe) static var cachedContext: String = ""

    private let loader = MiraSkillLoader.shared

    /// Skills the current plan actually grants — the source for both the Skills
    /// tab and the injected context. Drawn from the unified loader (built-ins +
    /// platform + user, plan-gated), no longer a hardcoded array.
    var all: [MiraSkill] { loader.skills }

    @Published private(set) var activeIDs: Set<String>

    private let defaultsKey = "mira_active_skill_ids"

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        activeIDs = Set(saved)
        loader.refresh()
        rebuildContext()
    }

    /// Rescans disk, re-applies plan gating, and rebuilds the injected context.
    /// Call when the Skills tab appears, after an add/remove, or on plan change.
    func refresh() {
        loader.refresh()
        rebuildContext()
        objectWillChange.send()
    }

    /// Re-applies plan gating without a disk rescan — for plan up/downgrades.
    func planChanged() {
        loader.applyPlanFilter()
        rebuildContext()
        objectWillChange.send()
    }

    func toggle(_ id: String) {
        let willActivate = !activeIDs.contains(id)
        if willActivate { activeIDs.insert(id) } else { activeIDs.remove(id) }
        UserDefaults.standard.set(Array(activeIDs), forKey: defaultsKey)
        rebuildContext()
        AudioCueService.shared.play(willActivate ? .skillUp : .skillDown)
    }

    func isActive(_ id: String) -> Bool { activeIDs.contains(id) }

    /// Activates every skill the current plan grants (the visible set).
    func selectAll() {
        let granted = all.map(\.id)
        guard !granted.isEmpty else { return }
        activeIDs = Set(granted)
        UserDefaults.standard.set(Array(activeIDs), forKey: defaultsKey)
        rebuildContext()
        AudioCueService.shared.play(.skillUp)
    }

    /// Deactivates every skill.
    func clearAll() {
        guard !activeIDs.isEmpty else { return }
        activeIDs.removeAll()
        UserDefaults.standard.set(Array(activeIDs), forKey: defaultsKey)
        rebuildContext()
        AudioCueService.shared.play(.skillDown)
    }

    private func rebuildContext() {
        Self.cachedContext = Self.buildContext(ids: activeIDs, all: all)
    }

    private static func buildContext(ids: Set<String>, all: [MiraSkill]) -> String {
        let active = all.filter { ids.contains($0.id) }
        guard !active.isEmpty else { return "" }
        return "\n\n" + active.map(\.context).joined(separator: "\n\n")
    }
}
