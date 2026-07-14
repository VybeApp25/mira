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

    // MARK: - Author from a goal (LA-1)

    struct AuthorError: Error { let message: String; init(_ m: String) { message = m } }

    /// The model's authored lesson: the curriculum plus a title/description we lift
    /// into the SKILL.md. `steps` reuses the on-disk StepDTO so it's validated by the
    /// exact same path SkillCatalog uses to load a bundle.
    private struct AuthoredLesson: Decodable {
        let title: String
        let description: String
        let steps: [StepDTO]
    }

    /// Authors a REAL lesson for `app` from a plain-language `goal` via the LLM,
    /// validates it against the honest-load check (every step must decode to a
    /// success check Mira can actually perform), and writes it as a `scaffolded`
    /// bundle. Unlike `scaffold(for:)` (a fixed template), this produces goal-specific
    /// steps that prefer vision-verified outcomes (LA-0). Throws with a human message
    /// on an empty goal, a malformed model response, or an unsupported check — never
    /// writes a half-valid bundle. See docs/architecture/learn_along.md (LA-1).
    @discardableResult
    func author(goal: String, app: LessonRegistry.AppEntry) async throws -> ScaffoldResult {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard goal.count >= 3 else { throw AuthorError("Tell me what you want to learn first.") }

        let raw: String
        do {
            raw = try await ClaudeService(apiKey: AppSecrets.anthropicAPIKey).authorLessonSteps(
                goal: goal, appName: app.name, bundleId: app.bundleId)
        } catch {
            // Surface the real cause (HTTP body / network) instead of a generic
            // "try again" — trimmed so a huge error body doesn't fill the sheet.
            let msg = String("\(error)".prefix(180))
            throw AuthorError("Couldn't reach the lesson author: \(msg)")
        }

        guard let data = raw.data(using: .utf8),
              let lesson = try? JSONDecoder().decode(AuthoredLesson.self, from: data) else {
            throw AuthorError("The generated lesson was malformed. Try rephrasing the goal.")
        }
        guard !lesson.steps.isEmpty else { throw AuthorError("The generated lesson had no steps.") }
        // Validate through the SAME gate SkillCatalog uses — a step that declares a
        // check Mira can't perform must fail authoring, not slip onto disk.
        for s in lesson.steps where s.toDomain() == nil {
            throw AuthorError("The lesson used an unsupported success check on step “\(s.id)”.")
        }

        // Unique slug so a second lesson for the same app/goal doesn't clobber the first.
        let base = Self.slug(for: "\(app.name)-\(goal)")
        let slug = uniqueSlug(base)
        let dir  = skillsDir.appendingPathComponent(slug, isDirectory: true)
        let fm   = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest = Self.authoredManifest(
                slug: slug, title: lesson.title, description: lesson.description, app: app)
            try manifest.write(to: dir.appendingPathComponent("SKILL.md"),
                               atomically: true, encoding: .utf8)
            // Re-serialize through SkillStepsDTO so the on-disk file is canonical and
            // carries our slug as the id (the model doesn't author the id).
            let stepsDTO = SkillStepsDTO(id: slug, title: lesson.title, steps: lesson.steps)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
            try enc.encode(stepsDTO).write(to: dir.appendingPathComponent("steps.json"))
            return ScaffoldResult(skillId: slug, bundleURL: dir)
        } catch let e as AuthorError {
            try? fm.removeItem(at: dir); throw e
        } catch {
            try? fm.removeItem(at: dir)
            throw AuthorError("Couldn't save the lesson. Please try again.")
        }
    }

    /// Appends -2, -3, … until the slug's folder doesn't already exist.
    private func uniqueSlug(_ base: String) -> String {
        let fm = FileManager.default
        var slug = base, n = 2
        while fm.fileExists(atPath: skillsDir.appendingPathComponent(slug).path) {
            slug = "\(base)-\(n)"; n += 1
        }
        return slug
    }

    private static func authoredManifest(slug: String, title: String,
                                         description: String, app: LessonRegistry.AppEntry) -> String {
        // Single-line the title/description so the simple frontmatter parser is happy.
        let t = title.replacingOccurrences(of: "\n", with: " ")
        let d = description.replacingOccurrences(of: "\n", with: " ")
        return """
        ---
        name: \(slug)
        title: \(t)
        description: \(d)
        domainApp: \(app.bundleId)
        grounding: \(app.grounding)
        version: 0.1.0
        scaffolded: true
        ---

        # \(t)

        Authored from a goal by Mira's Lesson author, so it's marked `scaffolded: true`
        and shows as **Unverified** until a real run proves each ring lands and the
        vision checks fire on the real app. Run it to verify, and refine any step whose
        target description or success check doesn't quite match what you see.
        """
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
