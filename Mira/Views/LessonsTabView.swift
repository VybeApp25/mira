import SwiftUI
import AppKit

// MARK: - Lessons tab (Teaching System — discoverability surface)
//
// A dedicated home for skill bundles, replacing the list that used to be buried
// at the bottom of Settings. Each lesson shows the app it teaches in (real app
// icon), a human title + description, and its honestly-derived progress.
// Starting a lesson resumes from the learner journal when there's a saved point.

struct LessonsTabView: View {
    @ObservedObject private var catalog = SkillCatalog.shared
    @ObservedObject private var learner = LearnerModel.shared
    @ObservedObject private var engine  = TeachingEngine.shared

    @State private var loadError: String?
    @State private var showScaffold = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if engine.phase == .running {
                activeBanner
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            if catalog.manifests.isEmpty && catalog.invalidBundles.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(catalog.manifests) { manifest in
                            LessonCard(
                                manifest: manifest,
                                progress: learner.progress(forSkillId: manifest.id),
                                isActive: engine.skill?.id == manifest.id && engine.phase == .running,
                                unverified: manifest.scaffolded && !learner.hasGroundedRun(forSkillId: manifest.id),
                                action: { start(manifest) }
                            )
                            .contextMenu {
                                Button { start(manifest, restart: true) } label: {
                                    Label("Restart from the beginning", systemImage: "arrow.counterclockwise")
                                }
                            }
                        }

                        if let err = loadError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.error)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 2)
                        }

                        if !catalog.invalidBundles.isEmpty {
                            needsAttention
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { catalog.refresh(); LessonScaffolder.shared.loadRegistry() }
        .sheet(isPresented: $showScaffold) {
            ScaffoldSheet { catalog.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(miraTeale)
                Text("Lessons")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button { showScaffold = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 11, weight: .semibold))
                        Text("Teach a new app").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(miraTeale)
                }
                .buttonStyle(.plain)
                .help("Generate a starter lesson for any installed app")
            }
            Text("Learn by doing — Mira draws on your screen and guides each step.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var activeBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Lesson in progress — \(engine.skill?.title ?? "")")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
            Spacer()
            Button { engine.stop() } label: {
                Text("Stop").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(miraTeale.opacity(0.12)))
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "graduationcap")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(DS.Colors.textTertiary)
            Text("No lessons yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Drop a skill bundle into\n~/Library/Application Support/Mira/Skills")
                .font(.system(size: 10, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    // Authoring feedback: bundles on disk that can't start, with the reason.
    private var needsAttention: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.warning)
                Text("Needs attention")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.top, 6)

            ForEach(catalog.invalidBundles) { bundle in
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(bundle.reason)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.warning.opacity(0.25), lineWidth: 1))
            }
        }
    }

    // MARK: Actions

    private func start(_ manifest: SkillManifest, restart: Bool = false) {
        loadError = nil
        switch SkillCatalog.shared.loadSkill(manifest) {
        case .success(let skill):
            let idx = restart ? 0 : LearnerModel.shared.resumeIndex(for: skill)
            TeachingEngine.shared.start(skill, fromStepIndex: idx)
        case .failure(let err):
            NSLog("[Lessons] load failed: %@", err.message)
            loadError = "Couldn't start “\(manifest.displayTitle)”: \(err.message)"
        }
    }
}

// MARK: - Lesson card

private struct LessonCard: View {
    let manifest: SkillManifest
    let progress: SkillProgress
    let isActive:  Bool
    let unverified: Bool
    let action:   () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                appIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(manifest.description)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let eyebrow = subtitleLine {
                        Text(eyebrow)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary.opacity(0.8))
                            .padding(.top, 1)
                    }
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 6) {
                    badge
                    startGlyph
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? miraTeale.opacity(0.10)
                                   : (hovering ? DS.Colors.surface3 : DS.Colors.surface2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? miraTeale.opacity(0.45) : DS.Colors.borderSubtle,
                            lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.005 : 1.0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    // App icon for the target app, or a graduationcap fallback if it isn't installed.
    @ViewBuilder private var appIcon: some View {
        if let img = Self.icon(for: manifest.domainApp) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DS.Colors.surface4)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "graduationcap.fill")
                    .font(.system(size: 16))
                    .foregroundColor(DS.Colors.textTertiary))
        }
    }

    // "Xcode · accessibility" — the app it runs in + how Mira grounds it.
    private var subtitleLine: String? {
        let app  = Self.appName(for: manifest.domainApp)
        let tier = manifest.grounding.map { $0 == "vision" ? "vision-guided" : "precise" }
        switch (app, tier) {
        case let (a?, t?): return "\(a) · \(t)"
        case let (a?, nil): return a
        case let (nil, t?): return t
        default: return nil
        }
    }

    @ViewBuilder private var badge: some View {
        // A scaffolded lesson hasn't had its ring proven to land yet — say so
        // honestly until the journal shows a real grounded run.
        if unverified {
            pill("Unverified", color: DS.Colors.warning)
        } else {
            switch progress.status {
            case .notAssessed:
                pill("Start", color: miraTeale)
            case .inProgress:
                pill(progress.resumeAfterStepId != nil ? "Resume" : "In progress",
                     color: DS.Colors.warning)
            case .mastered:
                pill(progress.reviewDue ? "Review" : "Mastered",
                     color: progress.reviewDue ? DS.Colors.warning : DS.Colors.success)
            }
        }
    }

    private var startGlyph: some View {
        Image(systemName: progress.resumeAfterStepId != nil ? "arrow.clockwise" : "play.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    // MARK: App lookup (cached)

    private static var iconCache: [String: NSImage] = [:]
    private static var nameCache: [String: String]  = [:]

    private static func appURL(for bundleId: String?) -> URL? {
        guard let bid = bundleId else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
    }

    static func icon(for bundleId: String?) -> NSImage? {
        guard let bid = bundleId else { return nil }
        if let c = iconCache[bid] { return c }
        guard let url = appURL(for: bid) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bid] = img
        return img
    }

    static func appName(for bundleId: String?) -> String? {
        guard let bid = bundleId else { return nil }
        if let c = nameCache[bid] { return c }
        guard let url = appURL(for: bid) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        nameCache[bid] = name
        return name
    }
}

// MARK: - Scaffold sheet (generate a starter lesson for any installed app)

private struct ScaffoldSheet: View {
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var scaffolder = LessonScaffolder.shared
    @State private var query = ""
    @State private var goal = ""
    @State private var note: String?
    @State private var errorNote: String?
    @State private var authoringApp: String?   // bundleId currently being authored

    private var apps: [LessonRegistry.AppEntry] {
        let all = scaffolder.registry?.apps ?? []
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Teach a new app")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button("Done") { onDone(); dismiss() }.buttonStyle(.plain)
                    .foregroundColor(miraTeale).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            Text("Describe what you want to learn — or paste a YouTube tutorial link — then pick the app. Mira authors a lesson with vision-checked steps (a tutorial link also opens alongside when you run it). Leave it blank for a plain starter. Either opens as **Unverified** until a real run proves it.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 8)

            TextField("A goal (“add a reverb send”) or a YouTube tutorial link", text: $goal)
                .textFieldStyle(.roundedBorder)
                .disabled(authoringApp != nil)
                .padding(.horizontal, 16).padding(.bottom, 6)

            TextField("Search \(scaffolder.registry?.apps.count ?? 0) installed apps…", text: $query)
                .textFieldStyle(.roundedBorder)
                .disabled(authoringApp != nil)
                .padding(.horizontal, 16).padding(.bottom, 8)

            if let note {
                Text(note).font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.success)
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }
            if let errorNote {
                Text(errorNote).font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 6)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(apps) { app in
                        Button { pick(app) } label: {
                            HStack(spacing: 10) {
                                if let img = LessonCard.icon(for: app.bundleId) {
                                    Image(nsImage: img).resizable().frame(width: 26, height: 26)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name).font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(DS.Colors.textPrimary)
                                    Text(app.grounding == "vision" ? "vision-guided" : "precise")
                                        .font(.system(size: 9)).foregroundColor(DS.Colors.textTertiary)
                                }
                                Spacer()
                                if authoringApp == app.bundleId {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: goal.trimmingCharacters(in: .whitespaces).isEmpty
                                          ? "plus.circle" : "sparkles")
                                        .font(.system(size: 13)).foregroundColor(miraTeale)
                                }
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DS.Colors.surface2))
                        }
                        .buttonStyle(.plain)
                        .disabled(authoringApp != nil)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(width: 360, height: 460)
        .onAppear { scaffolder.loadRegistry() }
    }

    /// A YouTube URL → author from that tutorial; a goal → author via the LLM; nothing
    /// → the fixed template starter.
    private func pick(_ app: LessonRegistry.AppEntry) {
        note = nil; errorNote = nil
        let text = goal.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            templateScaffold(app)
        } else if Self.isYouTubeURL(text) {
            authorTutorial(app)
        } else {
            authorLesson(app)
        }
    }

    private static func isYouTubeURL(_ s: String) -> Bool {
        let l = s.lowercased()
        return (l.contains("youtube.com/") || l.contains("youtu.be/"))
            && (l.hasPrefix("http://") || l.hasPrefix("https://"))
    }

    private func authorTutorial(_ app: LessonRegistry.AppEntry) {
        authoringApp = app.bundleId
        let url = goal
        Task {
            defer { authoringApp = nil }
            do {
                let result = try await scaffolder.authorFromTutorial(url: url, app: app)
                note = "Authored “\(result.skillId)” from the tutorial for \(app.name) — find it in Lessons (Unverified)."
                onDone()
            } catch let e as LessonScaffolder.AuthorError {
                errorNote = e.message
            } catch {
                errorNote = "Couldn't author from that tutorial. Please try again."
            }
        }
    }

    private func templateScaffold(_ app: LessonRegistry.AppEntry) {
        if scaffolder.scaffold(for: app) != nil {
            note = "Created “Get started in \(app.name)” — find it in Lessons (Unverified)."
        } else {
            note = "A lesson for \(app.name) already exists."
        }
        onDone()
    }

    private func authorLesson(_ app: LessonRegistry.AppEntry) {
        authoringApp = app.bundleId
        let goalText = goal
        Task {
            defer { authoringApp = nil }
            do {
                let result = try await scaffolder.author(goal: goalText, app: app)
                note = "Authored “\(result.skillId)” for \(app.name) — find it in Lessons (Unverified)."
                onDone()   // refresh the catalog so the new lesson appears
            } catch let e as LessonScaffolder.AuthorError {
                errorNote = e.message
            } catch {
                errorNote = "Couldn't author the lesson. Please try again."
            }
        }
    }
}
