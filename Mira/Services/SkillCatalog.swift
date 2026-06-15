import Foundation

// MARK: - Skill Catalog / Loader (Teaching System M3)
//
// Scans the skills directory for bundles, keeps their manifests resident
// (always-loaded, cheap), and loads a skill's full curriculum only when it's
// actually run (progressive disclosure). New domains are added by dropping a
// folder here — no recompile. See docs/architecture/teaching_system.md §5.

@MainActor
final class SkillCatalog: ObservableObject {
    static let shared = SkillCatalog()
    private init() {}

    /// Always-loaded manifests for every installed skill (startable lessons).
    @Published private(set) var manifests: [SkillManifest] = []

    /// Bundles that exist on disk but can't be started, with the reason. Surfaced
    /// in the Learn tab so authors get a feedback loop instead of a silent no-show.
    @Published private(set) var invalidBundles: [InvalidBundle] = []

    struct InvalidBundle: Identifiable, Equatable {
        var id: String { name }
        let name:   String   // folder name, or the lesson title once the manifest parses
        let reason: String
    }

    /// ~/Library/Application Support/Mira/Skills
    private var skillsDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Mira/Skills", isDirectory: true)
    }

    // MARK: - Public

    /// Seeds built-ins on first run, then (re)scans the directory. Cheap; safe to
    /// call whenever the skill list is shown — picks up newly dropped bundles.
    func refresh() {
        seedBuiltinsIfNeeded()
        let result = scan()
        manifests      = result.valid
        invalidBundles = result.invalid
    }

    struct SkillLoadError: Error { let message: String; init(_ m: String) { message = m } }

    /// Loads a skill's full curriculum on demand. Fails with a clear message if
    /// the bundle is malformed or declares a check Mira can't perform.
    func loadSkill(_ manifest: SkillManifest) -> Result<TeachingSkill, SkillLoadError> {
        let stepsURL = manifest.bundleURL.appendingPathComponent("steps.json")
        guard let data = try? Data(contentsOf: stepsURL) else {
            return .failure(.init("steps.json missing in \(manifest.name)"))
        }
        guard let dto = try? JSONDecoder().decode(SkillStepsDTO.self, from: data) else {
            return .failure(.init("steps.json is malformed in \(manifest.name)"))
        }
        var steps: [TeachingStep] = []
        for s in dto.steps {
            guard let step = s.toDomain() else {
                return .failure(.init("\(manifest.name): step \"\(s.id)\" uses an unsupported success check (\(s.successCheck.type))"))
            }
            steps.append(step)
        }
        guard !steps.isEmpty else { return .failure(.init("\(manifest.name) has no steps")) }
        return .success(TeachingSkill(id: dto.id, title: dto.title, steps: steps,
                                      domainApp: manifest.domainApp))
    }

    // MARK: - Scan

    private func scan() -> (valid: [SkillManifest], invalid: [InvalidBundle]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return ([], [])
        }
        var valid:   [SkillManifest] = []
        var invalid: [InvalidBundle] = []
        for dir in entries where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let folder = dir.lastPathComponent
            let md = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: md, encoding: .utf8) else {
                invalid.append(.init(name: folder, reason: "No SKILL.md in this folder.")); continue
            }
            guard let m = parseManifest(text, bundleURL: dir) else {
                invalid.append(.init(name: folder,
                    reason: "SKILL.md frontmatter needs an opening `---` and a `name:` line.")); continue
            }
            // Validate the curriculum so authors see problems up front. We decode and
            // discard — the steps stay on disk until the lesson actually runs (still
            // progressive disclosure; nothing curriculum-sized is retained here).
            if let reason = validationError(for: m) {
                invalid.append(.init(name: m.displayTitle, reason: reason))
            } else {
                valid.append(m)
            }
        }
        return (valid.sorted   { $0.name < $1.name },
                invalid.sorted { $0.name < $1.name })
    }

    /// nil when the bundle's steps.json loads cleanly; otherwise the reason.
    private func validationError(for manifest: SkillManifest) -> String? {
        if case .failure(let e) = loadSkill(manifest) { return e.message }
        return nil
    }

    /// Parses the YAML-style frontmatter (between the first two `---` fences) of a
    /// SKILL.md into a manifest. Simple `key: value` lines — no YAML dependency.
    private func parseManifest(_ text: String, bundleURL: URL) -> SkillManifest? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            guard let colon = t.firstIndex(of: ":") else { continue }
            let key = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(t[t.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { fields[key] = val }
        }
        guard let name = fields["name"], !name.isEmpty else { return nil }
        return SkillManifest(
            id: name,
            name: name,
            description: fields["description"] ?? "",
            domainApp: fields["domainApp"],
            grounding: fields["grounding"],
            version: fields["version"],
            bundleURL: bundleURL,
            title: fields["title"],
            scaffolded: (fields["scaffolded"]?.lowercased() == "true"))
    }

    // MARK: - Seed built-ins

    private func seedBuiltinsIfNeeded() {
        let fm = FileManager.default
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let darkDir = skillsDir.appendingPathComponent("macos-dark-mode", isDirectory: true)
        guard !fm.fileExists(atPath: darkDir.path) else { return }
        try? fm.createDirectory(at: darkDir, withIntermediateDirectories: true)
        try? Self.darkModeManifest.write(to: darkDir.appendingPathComponent("SKILL.md"),
                                         atomically: true, encoding: .utf8)
        try? Self.darkModeSteps.write(to: darkDir.appendingPathComponent("steps.json"),
                                      atomically: true, encoding: .utf8)
    }

    // The built-in Dark Mode skill, as a bundle (migrated from the M2 hardcoded
    // TeachingSkills.darkMode — same content, now data).
    private static let darkModeManifest = """
    ---
    name: macos-dark-mode
    title: Turn on Dark Mode
    description: Turn on Dark Mode in macOS via System Settings → Appearance.
    domainApp: com.apple.systempreferences
    grounding: accessibility
    version: 0.1.0
    ---

    Teaches switching macOS to Dark Mode. The final step is verified directly from
    the system appearance, so completion is observed, not assumed.
    """

    private static let darkModeSteps = """
    {
      "id": "macos-dark-mode",
      "title": "Turn on Dark Mode",
      "steps": [
        {
          "id": "open-settings",
          "instruction": "Open System Settings (click it in the Dock or hit ⌘-Space and type \\"System Settings\\").",
          "target": null,
          "successCheck": { "type": "appFrontmost", "bundleId": "com.apple.systempreferences" },
          "remediation": "Still waiting for System Settings to open — launch it and I'll continue.",
          "observeWindow": 25
        },
        {
          "id": "open-appearance",
          "instruction": "In the sidebar, click \\"Appearance\\".",
          "target": { "description": "the Appearance row in the System Settings sidebar" },
          "successCheck": { "type": "userConfirmation" },
          "remediation": "Tap Done once you're on the Appearance screen.",
          "observeWindow": 20
        },
        {
          "id": "choose-dark",
          "instruction": "Choose the \\"Dark\\" appearance option at the top.",
          "target": { "description": "the Dark appearance thumbnail option" },
          "successCheck": { "type": "darkModeEnabled" },
          "remediation": "Click the Dark thumbnail — I'll detect it the moment your Mac switches.",
          "observeWindow": 30
        }
      ]
    }
    """
}
