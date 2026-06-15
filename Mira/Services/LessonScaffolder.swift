import Foundation

// MARK: - Lesson Scaffolder (Teaching System — namespace future-proofing)
//
// Breadth without lying. Instead of pre-baking hundreds of static lesson
// bundles (every one an unverified guess at where controls are), we keep a
// REGISTRY of the whole namespace — every installed app + the Composio
// integration catalog — and GENERATE a starter bundle for any of them on
// demand. A scaffolded bundle is marked `scaffolded: true`, which the Learn tab
// surfaces as "Unverified" until a real run proves its ring lands
// (LearnerModel.hasGroundedRun). Authoring never certifies a lesson; only an
// observed grounded run does. See docs/architecture/teaching_system.md.

// MARK: - Registry model (_registry.json in the Skills dir)

struct LessonRegistry: Codable {
    let version: String
    var generatedAt: String?
    var note: String?
    let apps: [AppEntry]
    let integrations: [IntegrationEntry]

    struct AppEntry: Codable, Identifiable, Equatable {
        var id: String { bundleId }
        let bundleId: String
        let name: String
        var path: String?
        let grounding: String        // "accessibility" (Apple/native AX) | "vision"
    }

    struct IntegrationEntry: Codable, Identifiable, Equatable {
        var id: String { slug }
        let slug: String
        let name: String
        let surface: String          // "web" — API/browser-grounded, not a native window
        let source: String           // "composio"
    }
}

@MainActor
final class LessonScaffolder: ObservableObject {
    static let shared = LessonScaffolder()
    private init() {}

    @Published private(set) var registry: LessonRegistry?

    /// ~/Library/Application Support/Mira/Skills (same dir SkillCatalog scans).
    private var skillsDir: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Mira/Skills", isDirectory: true)
    }
    private var registryURL: URL { skillsDir.appendingPathComponent("_registry.json") }

    // MARK: - Registry

    /// Loads the registry from disk; if it's missing, builds one by scanning the
    /// installed apps so the namespace is always current (picks up newly
    /// installed apps without a rebuild).
    @discardableResult
    func loadRegistry() -> LessonRegistry? {
        if let data = try? Data(contentsOf: registryURL),
           let reg = try? JSONDecoder().decode(LessonRegistry.self, from: data) {
            registry = reg
            return reg
        }
        let built = buildRegistryFromDisk()
        if let data = try? JSONEncoder().encodeSorted(built) {
            try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            try? data.write(to: registryURL)
        }
        registry = built
        return built
    }

    /// Enumerates installed apps (the native, teachable namespace). Integrations
    /// are carried from any existing registry file; a fresh disk build leaves them
    /// empty (they sync from the Composio catalog, not from local disk).
    private func buildRegistryFromDisk() -> LessonRegistry {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications",
                     "/System/Applications/Utilities", "/Applications/Utilities",
                     NSHomeDirectory() + "/Applications"]
        var seen: [String: LessonRegistry.AppEntry] = [:]
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let appPath = root + "/" + item
                let info = appPath + "/Contents/Info.plist"
                guard let plist = NSDictionary(contentsOfFile: info),
                      let bid = plist["CFBundleIdentifier"] as? String, seen[bid] == nil else { continue }
                let name = (plist["CFBundleName"] as? String)
                    ?? (plist["CFBundleDisplayName"] as? String)
                    ?? (item as NSString).deletingPathExtension
                seen[bid] = .init(bundleId: bid, name: name, path: appPath,
                                  grounding: bid.hasPrefix("com.apple.") ? "accessibility" : "vision")
            }
        }
        let apps = seen.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return LessonRegistry(version: "0.1.0",
                              generatedAt: ISO8601DateFormatter().string(from: .now),
                              note: "Auto-built from installed apps.",
                              apps: apps, integrations: [])
    }

    // MARK: - Scaffold

    struct ScaffoldResult { let skillId: String; let bundleURL: URL }

    /// Generates an honest starter bundle for an app and writes it to the Skills
    /// dir. The bundle is `scaffolded: true` (→ "Unverified") and contains a
    /// runnable skeleton: open the app (observed), one ringed control to learn,
    /// and a user-confirmed task step. It is a SEED to refine, never a finished,
    /// pre-verified lesson. Returns nil if a bundle for this app already exists.
    @discardableResult
    func scaffold(for app: LessonRegistry.AppEntry, taskNoun: String = "task") -> ScaffoldResult? {
        let slug = Self.slug(for: app.name)
        let dir = skillsDir.appendingPathComponent(slug, isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { return nil }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.manifest(slug: slug, app: app, taskNoun: taskNoun)
                .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            try Self.steps(slug: slug, app: app, taskNoun: taskNoun)
                .write(to: dir.appendingPathComponent("steps.json"), atomically: true, encoding: .utf8)
            return ScaffoldResult(skillId: slug, bundleURL: dir)
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    static func slug(for name: String) -> String {
        let lowered = name.lowercased()
        let kebab = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        var s = String(kebab)
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func manifest(slug: String, app: LessonRegistry.AppEntry, taskNoun: String) -> String {
        """
        ---
        name: \(slug)
        title: Get started in \(app.name)
        description: A starter lesson for \(app.name) — open it and learn one core action. Refine the steps to teach a real \(taskNoun).
        domainApp: \(app.bundleId)
        grounding: \(app.grounding)
        version: 0.1.0
        scaffolded: true
        ---

        # Get started in \(app.name) (scaffolded starter)

        Machine-generated by the Lesson Scaffolder, so it's marked `scaffolded: true`
        and shows as **Unverified** in Lessons until a real run proves its ring lands
        on a real control (nothing here is hand-verified yet — that's the honest
        default). \(app.grounding == "vision"
            ? "This app has a thin Accessibility tree, so `grounding: vision` and steps lean on user confirmation."
            : "This app exposes Accessibility, so `grounding: accessibility` — the ring should land precisely once refined.")

        To turn this seed into a real lesson: replace the middle steps with the
        actual controls of the \(taskNoun) you want to teach, describing each target
        the way you'd point it out to a person, then run it to verify (see
        AUTHORING.md).
        """
    }

    private static func steps(slug: String, app: LessonRegistry.AppEntry, taskNoun: String) -> String {
        """
        {
          "id": "\(slug)",
          "title": "Get started in \(app.name)",
          "steps": [
            {
              "id": "open-app",
              "instruction": "Open \(app.name) — find it in your Dock, or press ⌘-Space and type \\"\(app.name)\\". I'll wait until it's in front.",
              "target": null,
              "successCheck": { "type": "appFrontmost", "bundleId": "\(app.bundleId)" },
              "remediation": "Still waiting for \(app.name) to come to the front — open it and I'll continue.",
              "observeWindow": 40
            },
            {
              "id": "find-main-control",
              "instruction": "Let's find the main controls. Look at the toolbar at the top of the \(app.name) window.",
              "target": { "description": "the primary toolbar at the top of the \(app.name) window" },
              "successCheck": { "type": "userConfirmation" },
              "remediation": "Tap Done once you can see the toolbar.",
              "observeWindow": 30
            },
            {
              "id": "do-task",
              "instruction": "Now do the \(taskNoun) you came to learn. Take your time — tap Done when you've finished.",
              "target": null,
              "successCheck": { "type": "userConfirmation" },
              "remediation": "Tap Done once you've completed the \(taskNoun).",
              "observeWindow": 60
            }
          ]
        }
        """
    }
}

private extension JSONEncoder {
    func encodeSorted<T: Encodable>(_ value: T) throws -> Data {
        outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encode(value)
    }
}
