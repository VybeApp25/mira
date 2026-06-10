import AppKit
import Combine

// Maps a frontmost-app bundle-ID prefix → the skill ID Mira can help with.
private let appToSkill: [(prefix: String, skillID: String)] = [
    ("com.notion",           "artifacts"),
    ("com.linear",           "repo-operator"),
    ("com.spotify",          "creative-studio"),
    ("com.apple.Notes",      "docs"),
    ("com.apple.reminders",  "artifacts"),
    ("com.github",           "repo-operator"),
    ("md.obsidian",          "docs"),
    ("com.airtable",         "spreadsheet"),
    ("com.vercel",           "vercel-deploy"),
    ("com.microsoft.VSCode", "repo-operator"),
    ("com.google.Chrome",    "research-report"),
    ("com.apple.Safari",     "research-report"),
    ("com.figma",            "creative-studio"),
]

struct SidecarSuggestion {
    let skillID:  String
    let appName:  String
    let headline: String      // "Mira can help with Notion"
}

@MainActor
final class SidecarSuggestionService: ObservableObject {
    static let shared = SidecarSuggestionService()

    @Published private(set) var active: SidecarSuggestion? = nil

    // UserDefaults key → set of skill IDs the user has already seen/dismissed
    private let acknowledgedKey = "mira_sidecar_acknowledged_v1"
    private var acknowledged: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: acknowledgedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: acknowledgedKey) }
    }

    private var dwellStart:   Date?
    private var dwellSkillID: String?
    private var autoDismiss:  Task<Void, Never>?
    private let dwellThreshold: TimeInterval = 90

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    // MARK: - App change

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleID = app?.bundleIdentifier ?? ""
        let appName  = app?.localizedName    ?? ""

        // Find the matching skill
        guard let pair = appToSkill.first(where: { bundleID.hasPrefix($0.prefix) }) else {
            resetDwell()
            return
        }
        let skillID = pair.skillID

        // Already acknowledged, already active, or already showing — skip
        if acknowledged.contains(skillID)              { return }
        if SkillStore.shared.isActive(skillID)         { return }

        if dwellSkillID == skillID {
            // Same app — check if threshold crossed
            checkDwell(skillID: skillID, appName: appName)
        } else {
            // New app context — reset dwell
            dwellSkillID = skillID
            dwellStart   = Date()
            // Schedule a check after the dwell threshold
            Task {
                try? await Task.sleep(nanoseconds: UInt64(dwellThreshold * 1_000_000_000))
                checkDwell(skillID: skillID, appName: appName)
            }
        }
    }

    private func checkDwell(skillID: String, appName: String) {
        guard let start = dwellStart,
              Date().timeIntervalSince(start) >= dwellThreshold,
              !acknowledged.contains(skillID),
              !SkillStore.shared.isActive(skillID) else { return }

        let skill = MiraSkillCatalog.all.first { $0.id == skillID }
        show(SidecarSuggestion(
            skillID:  skillID,
            appName:  appName,
            headline: "Mira has a \(skill?.name ?? "skill") for \(appName)"
        ))
    }

    private func resetDwell() {
        dwellSkillID = nil
        dwellStart   = nil
    }

    // MARK: - Show / dismiss

    func show(_ suggestion: SidecarSuggestion) {
        active = suggestion
        autoDismiss?.cancel()
        autoDismiss = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000) // 8 s
            guard !Task.isCancelled else { return }
            active = nil
        }
    }

    // User tapped "Got it" — acknowledge + enable the skill
    func accept() {
        guard let s = active else { return }
        var ack = acknowledged
        ack.insert(s.skillID)
        acknowledged = ack
        if !SkillStore.shared.isActive(s.skillID) {
            SkillStore.shared.toggle(s.skillID)
        }
        dismiss()
    }

    // User tapped "×" — just dismiss without enabling
    func dismiss() {
        autoDismiss?.cancel()
        if let s = active {
            var ack = acknowledged
            ack.insert(s.skillID)
            acknowledged = ack
        }
        active = nil
    }
}
