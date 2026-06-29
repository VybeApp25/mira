import Foundation

// MARK: - Unified Skill Loader
//
// Produces the single, merged list of prompt-skills the app uses, drawn from
// three layers that never mix on disk:
//
//   1. Built-ins      — `MiraSkillCatalog.all`, compiled into the app.
//   2. Platform skills — SKILL.md folders you ship and push via app updates.
//                        Seeded from the app bundle's `Skills/` resource into
//                        `…/Application Support/Mira/PromptSkills/platform`
//                        (mirrored on every launch, so updates propagate).
//   3. User skills     — SKILL.md folders a user drops via the notch Skills tab,
//                        living in `…/Application Support/Mira/PromptSkills/user`.
//
// Built-ins + platform skills are "reserved": a user skill whose id collides
// with one is rejected (surfaced in `invalid`) so a personal skill can never
// silently shadow one you patch later. This is the prompt-skill counterpart to
// `SkillCatalog` (the Teaching System) — same folder-bundle shape, different
// consumer (the Claude system prompt instead of guided lessons), so it uses its
// own directory and never touches `Mira/Skills`.

@MainActor
final class MiraSkillLoader: ObservableObject {
    static let shared = MiraSkillLoader()
    private init() {}

    /// The skills the current plan grants, in priority order (built-ins →
    /// platform → user). Free sees none; Pro sees built-ins + platform; Ultra
    /// additionally sees user-authored ones. Re-derived from `loaded` on every
    /// `refresh()` and `applyPlanFilter()`, so a mid-session upgrade lands
    /// without rescanning disk.
    @Published private(set) var skills: [MiraSkill] = []

    /// Everything found on disk, tagged with its origin, before plan-gating.
    /// Drives the Skills tab's "X locked on your plan" affordances.
    private(set) var loaded: [(skill: MiraSkill, origin: Origin)] = []

    /// Folders that exist on disk but couldn't be loaded, with the reason —
    /// surfaced in the Skills tab so authors get a feedback loop, not a silent
    /// no-show.
    @Published private(set) var invalid: [InvalidSkill] = []

    struct InvalidSkill: Identifiable, Equatable {
        var id: String { origin.rawValue + "/" + folder }
        let folder: String
        let reason: String
        let origin: Origin
    }

    enum Origin: String { case builtin, platform, user }

    /// ids a user skill may not override (built-ins + platform). Populated by
    /// `refresh()`; read by the Add-Skill validator in the Skills tab.
    private(set) var reservedIDs: Set<String> = []

    /// Whether the current plan permits user-authored skills (Ultra only). The
    /// Skills tab uses this to show/hide the "Add Skill" affordance.
    var canAddUserSkills: Bool {
        EntitlementService.shared.plan.allowedSkillOrigins.contains(.user)
    }

    // MARK: - Directories

    private var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira", isDirectory: true)
    }

    /// Mirrored from the app bundle on launch — treat as read-only.
    var platformDir: URL { appSupport.appendingPathComponent("PromptSkills/platform", isDirectory: true) }

    /// Where the notch "Add Skill" flow writes; survives app updates.
    var userDir: URL { appSupport.appendingPathComponent("PromptSkills/user", isDirectory: true) }

    /// Platform skills shipped inside the app bundle (`Mira.app/Contents/Resources/Skills`).
    /// Absent until we add the resource folder — the loader degrades gracefully.
    private var bundledSkillsDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Skills", isDirectory: true)
    }

    // MARK: - Public

    /// Seeds platform skills from the bundle, then rebuilds the merged list.
    /// Cheap and idempotent — safe to call whenever the Skills tab appears or a
    /// user adds/removes a skill.
    func refresh() {
        syncPlatformFromBundle()

        var merged: [(skill: MiraSkill, origin: Origin)] = []
        var bad:    [InvalidSkill] = []
        var seen    = Set<String>()

        // 1. Built-ins — always present, highest precedence.
        for s in MiraSkillCatalog.all where seen.insert(s.id).inserted {
            merged.append((s, .builtin))
        }
        // 2. Platform skills — reserved alongside built-ins.
        load(dir: platformDir, origin: .platform, reserved: true,
             into: &merged, bad: &bad, seen: &seen)

        // Freeze the reserved set before loading user skills.
        reservedIDs = seen

        // 3. User skills — rejected on collision with a reserved id.
        load(dir: userDir, origin: .user, reserved: false,
             into: &merged, bad: &bad, seen: &seen)

        loaded  = merged
        invalid = bad
        applyPlanFilter()
    }

    /// Re-derives the published `skills` from `loaded` using the current plan's
    /// allowed origins. Call this (without a disk rescan) when the plan changes.
    func applyPlanFilter() {
        let allowed = EntitlementService.shared.plan.allowedSkillOrigins
        skills = loaded.filter { allowed.contains($0.origin) }.map(\.skill)
    }

    /// Validates a SKILL.md folder for import without mutating state — used by the
    /// Add-Skill flow before copying into `userDir`. Returns nil if importable,
    /// otherwise a human-facing reason.
    func importBlocker(forFolderNamed folder: String, skillMarkdown text: String) -> String? {
        guard let parsed = Self.parse(text) else {
            return "SKILL.md needs an opening `---`, a `name:` line, and a closing `---`."
        }
        if reservedIDs.contains(parsed.fields["name"] ?? "") {
            return "“\(parsed.fields["name"] ?? folder)” is the name of a built-in or platform skill — pick a different name."
        }
        return nil
    }

    // MARK: - Loading

    private func load(dir: URL, origin: Origin, reserved: Bool,
                      into merged: inout [(skill: MiraSkill, origin: Origin)],
                      bad: inout [InvalidSkill], seen: inout Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }

        for folderURL in entries
        where (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let folder = folderURL.lastPathComponent
            let md = folderURL.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: md, encoding: .utf8) else {
                bad.append(.init(folder: folder, reason: "No SKILL.md in this folder.", origin: origin))
                continue
            }
            guard let parsed = Self.parse(text), let name = parsed.fields["name"], !name.isEmpty else {
                bad.append(.init(folder: folder,
                    reason: "SKILL.md frontmatter needs an opening `---` and a `name:` line.",
                    origin: origin))
                continue
            }
            guard seen.insert(name).inserted else {
                // A user skill collided with a reserved (built-in/platform) id.
                let reason = reserved
                    ? "Duplicate skill id “\(name)” — skipped."
                    : "“\(name)” is already provided by a built-in or platform skill."
                bad.append(.init(folder: folder, reason: reason, origin: origin))
                continue
            }
            merged.append((skill(from: parsed, id: name, origin: origin), origin))
        }
    }

    /// Maps parsed SKILL.md frontmatter + body onto a `MiraSkill`. The markdown
    /// body becomes the system-prompt context; frontmatter supplies card metadata.
    private func skill(from parsed: Parsed, id: String, origin: Origin) -> MiraSkill {
        let f = parsed.fields
        let description = f["description"] ?? ""
        let category = Self.category(f["category"])
        let body = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Context is the body; fall back to the description so a metadata-only
        // skill still injects something meaningful.
        let context = body.isEmpty ? "Skill active: \(f["name"] ?? id).\n\(description)" : body
        return MiraSkill(
            id: id,
            name: f["title"] ?? Self.humanize(id),
            tagline: f["tagline"] ?? description,
            icon: f["icon"] ?? category.icon,
            category: category,
            context: context)
    }

    // MARK: - Platform seeding

    /// Mirrors the bundled `Skills/` folder into `platformDir`, replacing it so
    /// removed or edited platform skills propagate on app update. No-op if the
    /// app ships no bundled skills yet.
    private func syncPlatformFromBundle() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupport.appendingPathComponent("PromptSkills", isDirectory: true),
                                withIntermediateDirectories: true)
        guard let src = bundledSkillsDir,
              (try? src.checkResourceIsReachable()) == true else { return }
        try? fm.removeItem(at: platformDir)
        try? fm.copyItem(at: src, to: platformDir)
    }

    // MARK: - Frontmatter parsing

    struct Parsed { let fields: [String: String]; let body: String }

    /// Splits a SKILL.md into `key: value` frontmatter (between the first two
    /// `---` fences) and the markdown body after the closing fence. No YAML
    /// dependency — mirrors `SkillCatalog.parseManifest`, but also returns the body.
    static func parse(_ text: String) -> Parsed? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        var bodyStart: Int? = nil
        for i in 1..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "---" { bodyStart = i + 1; break }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(t[t.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { fields[key] = val }
        }
        guard let start = bodyStart else { return nil } // no closing fence
        let body = lines[start...].joined(separator: "\n")
        return Parsed(fields: fields, body: body)
    }

    // MARK: - Helpers

    private static func category(_ raw: String?) -> MiraSkill.Category {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .productivity }
        return MiraSkill.Category.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
            ?? .productivity
    }

    /// "clone-website" → "Clone Website".
    private static func humanize(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Plan gating
//
// Free gets no skills. Pro gets the skills we ship and push via app updates
// (built-ins + platform). Ultra additionally gets its own user-authored skills.
extension SubscriptionPlan {
    var allowedSkillOrigins: Set<MiraSkillLoader.Origin> {
        switch self {
        case .free:  return []
        case .pro:   return [.builtin, .platform]
        case .ultra: return [.builtin, .platform, .user]
        }
    }
}

