import SwiftUI

// MARK: - CommunityBrowseView (Gap B Phase 3)
//
// Browse & install approved community skills, and publish your own. Community
// skills are UNREVIEWED by Mira and never auto-activated on install — the user
// activates explicitly from the Skills grid. Publishing runs a server-side
// Claude moderation pass. See docs/specs/community-skills-moderation.md.

struct CommunityBrowseView: View {
    @ObservedObject private var loader = MiraSkillLoader.shared
    private let svc = CommunitySkillService.shared

    enum Mode: String, CaseIterable { case browse = "Browse", publish = "Publish yours" }
    @State private var mode: Mode = .browse

    @State private var query = ""
    @State private var catalog: [CommunitySkill] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var installed: Set<String> = []

    @State private var publishing: String?              // skill id in flight
    @State private var outcomes:  [String: String] = [:] // skill id → status label

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Community skills").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            Text("Community skills are unreviewed by Mira. Read what a skill does before you activate it.")
                .font(.system(size: 10.5)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if mode == .browse { browse } else { publish }
        }
        .padding(18)
        .frame(width: 460, height: 460)
        .task { await load() }
    }

    // MARK: - Browse

    private var browse: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("Search skills…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { Task { await load() } }
            }
            .padding(8).background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let e = loadError {
                Text(e).font(.system(size: 11)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(catalog) { skill in catalogCard(skill) }
                        if catalog.isEmpty {
                            Text("No skills found.").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 30)
                        }
                    }
                }
            }
        }
    }

    private func catalogCard(_ s: CommunitySkill) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: s.icon).font(.system(size: 14)).foregroundColor(miraTeale)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                Text(s.tagline).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Text("by @\(s.author_handle ?? "someone") · \(s.downloads ?? 0) installs")
                    .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
            }
            Spacer()
            if installed.contains(s.slug) {
                Label("Added", systemImage: "checkmark").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            } else {
                Button("Add") { install(s) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(miraTeale).clipShape(Capsule())
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Publish

    private var publish: some View {
        ScrollView {
            VStack(spacing: 8) {
                if loader.userSkills.isEmpty {
                    Text("Create a skill first (the wand button), then publish it here for others.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 20)
                }
                ForEach(loader.userSkills) { skill in
                    HStack(spacing: 10) {
                        Image(systemName: skill.icon).font(.system(size: 14)).foregroundColor(miraTeale).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                            if let outcome = outcomes[skill.id] {
                                Text(outcome).font(.system(size: 10)).foregroundColor(.secondary)
                            } else {
                                Text(skill.tagline).font(.system(size: 10.5)).foregroundColor(.white.opacity(0.55))
                            }
                        }
                        Spacer()
                        if publishing == skill.id {
                            ProgressView().controlSize(.small)
                        } else if outcomes[skill.id] == nil {
                            Button("Publish") { publishSkill(skill) }
                                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                                .foregroundColor(miraTeale)
                        }
                    }
                    .padding(10).background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        loading = true; loadError = nil
        defer { loading = false }
        do { catalog = try await svc.fetchCatalog(query: query) }
        catch { loadError = error.localizedDescription }
    }

    private func install(_ s: CommunitySkill) {
        do { _ = try svc.install(s); installed.insert(s.slug) }
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    private func publishSkill(_ skill: MiraSkill) {
        guard let md = loader.markdownForUserSkill(id: skill.id) else { return }
        publishing = skill.id
        Task {
            defer { publishing = nil }
            do {
                let out = try await svc.publish(markdown: md)
                switch out.status {
                case "approved": outcomes[skill.id] = "Published ✓ — live in the catalog"
                case "rejected": outcomes[skill.id] = "Rejected: \(out.reason)"
                default:         outcomes[skill.id] = "Submitted — pending review"
                }
            } catch {
                outcomes[skill.id] = (error as? LocalizedError)?.errorDescription ?? "Publish failed"
            }
        }
    }
}
