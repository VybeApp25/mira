import SwiftUI
import UniformTypeIdentifiers

struct SkillsTabView: View {
    @ObservedObject var miraState: MiraState

    @ObservedObject private var store        = SkillStore.shared
    @ObservedObject private var loader       = MiraSkillLoader.shared
    @ObservedObject private var entitlements = EntitlementService.shared

    @State private var importing   = false   // file picker open
    @State private var importError: String?  // non-nil → error alert
    @State private var showPaywall = false

    // Create-a-skill flow (Gap B)
    @State private var creating    = false   // create sheet open
    @State private var browsing    = false   // community browse sheet
    @State private var createDesc  = ""
    @State private var generating  = false
    @State private var createError: String?

    /// User-authored bundles that failed to load — shown so authors get feedback.
    private var userIssues: [MiraSkillLoader.InvalidSkill] {
        loader.invalid.filter { $0.origin == .user }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            content
            if !store.activeIDs.isEmpty {
                activeBar
            }
        }
        .onAppear { store.refresh() }
        // A plan up/downgrade re-gates the list and the injected context.
        .onChange(of: entitlements.plan) { _, _ in store.planChanged() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert("Couldn't add skill", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $creating) { createSkillSheet }
        .sheet(isPresented: $browsing) { CommunityBrowseView() }
    }

    // MARK: - Create a skill (Gap B)

    private var createSkillSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a skill")
                .font(.system(size: 15, weight: .semibold))
            Text("Describe what you want this skill to do. Mira writes it, and it's ready to activate.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            TextEditor(text: $createDesc)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 92)
                .padding(6)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let e = createError {
                Text(e)
                    .font(.system(size: 10.5))
                    .foregroundColor(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { creating = false }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await generateSkill() }
                } label: {
                    HStack(spacing: 5) {
                        if generating { ProgressView().controlSize(.small) }
                        Text(generating ? "Creating…" : "Create skill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(generating || createDesc.trimmingCharacters(in: .whitespaces).count < 8)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func generateSkill() async {
        let desc = createDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard desc.count >= 8 else { return }
        generating = true
        createError = nil
        defer { generating = false }
        do {
            let markdown = try await ClaudeService(apiKey: miraState.effectiveAPIKey)
                .generateSkillMarkdown(description: desc)
            let name = try loader.createUserSkill(markdown: markdown)
            if !store.isActive(name) { store.toggle(name) }   // auto-activate the new skill
            createDesc = ""
            creating = false
        } catch {
            createError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Content (plan-gated)

    @ViewBuilder
    private var content: some View {
        if entitlements.plan == .free {
            upsell
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(MiraSkill.Category.allCases, id: \.self) { category in
                        let skills = store.all.filter { $0.category == category }
                        if !skills.isEmpty {
                            Section {
                                ForEach(skills) { skill in
                                    SkillCard(skill: skill, isActive: store.isActive(skill.id)) {
                                        store.toggle(skill.id)
                                    }
                                }
                            } header: {
                                sectionHeader(category)
                            }
                        }
                    }
                }
                .padding(10)

                if !userIssues.isEmpty { issuesList }
            }
        }
    }

    private func sectionHeader(_ category: MiraSkill.Category) -> some View {
        HStack(spacing: 4) {
            Image(systemName: category.icon)
                .font(.system(size: 9, weight: .semibold))
            Text(category.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(.secondary.opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .gridCellColumns(2)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text("Skills")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            // Bulk select / deselect — only meaningful when skills are visible.
            if entitlements.plan != .free {
                Button("Select all") { store.selectAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(allSelected ? .secondary.opacity(0.35) : miraTeale)
                    .disabled(allSelected)
                Text("·").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.4))
                Button("Clear all") { store.clearAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(store.activeIDs.isEmpty ? .secondary.opacity(0.35) : .secondary)
                    .disabled(store.activeIDs.isEmpty)
            }
            // Add your own — Ultra only.
            if loader.canAddUserSkills {
                Button { browsing = true } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(miraTeale)
                }
                .buttonStyle(.plain)
                .help("Browse & publish community skills")
                Button { createError = nil; creating = true } label: {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(miraTeale)
                }
                .buttonStyle(.plain)
                .help("Create a skill by describing it")
                Button { importing = true } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(miraTeale)
                }
                .buttonStyle(.plain)
                .help("Add a skill folder (SKILL.md)")
            }
            Text("\(store.activeIDs.count) active")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// True when every granted skill is already active — disables "Select all".
    private var allSelected: Bool {
        let granted = Set(store.all.map(\.id))
        return !granted.isEmpty && granted.isSubset(of: store.activeIDs)
    }

    // MARK: - Free-plan upsell

    private var upsell: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(miraTeale)
            Text("Skills are a paid feature")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("Upgrade to Pro for Mira's built-in skills, or Ultra to add your own.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Button { showPaywall = true } label: {
                Text("See plans")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(miraTeale.opacity(0.85)))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Invalid user skills

    private var issuesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEEDS ATTENTION")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.orange.opacity(0.8))
            ForEach(userIssues) { issue in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.folder)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        Text(issue.reason)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    // MARK: - Active bar

    private var activeBar: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text(activeLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
    }

    private var activeLabel: String {
        let names = store.all.filter { store.isActive($0.id) }.map(\.name)
        if names.count <= 2 { return names.joined(separator: " · ") + " enabled" }
        return "\(names.prefix(2).joined(separator: " · ")) +\(names.count - 2) more"
    }

    // MARK: - Import

    /// Copies a user-picked skill folder (must contain SKILL.md) into the loader's
    /// user dir after validating it. Rejects names that collide with built-in or
    /// platform skills so a personal skill can't shadow one we patch later.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard loader.canAddUserSkills else { return }
        switch result {
        case .failure(let err):
            importError = err.localizedDescription
        case .success(let urls):
            guard let src = urls.first else { return }
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }

            let md = src.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: md, encoding: .utf8) else {
                importError = "That folder has no SKILL.md at its top level."
                return
            }
            if let reason = loader.importBlocker(forFolderNamed: src.lastPathComponent, skillMarkdown: text) {
                importError = reason
                return
            }
            let fm = FileManager.default
            let dest = loader.userDir.appendingPathComponent(src.lastPathComponent, isDirectory: true)
            do {
                try fm.createDirectory(at: loader.userDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
            } catch {
                importError = "Couldn't copy the skill: \(error.localizedDescription)"
                return
            }
            store.refresh()
            AudioCueService.shared.play(.skillUp)
        }
    }
}

// MARK: - Skill card

private struct SkillCard: View {
    let skill:    MiraSkill
    let isActive: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: skill.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isActive ? miraTeale : .secondary)
                        .frame(width: 20)
                    Spacer()
                    // Toggle indicator
                    Circle()
                        .fill(isActive ? miraTeale : Color.white.opacity(0.15))
                        .frame(width: 8, height: 8)
                }
                Text(skill.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? .white : .white.opacity(0.75))
                    .lineLimit(1)
                Text(skill.tagline)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive
                        ? miraTeale.opacity(0.12)
                        : Color.white.opacity(isHovered ? 0.07 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isActive ? miraTeale.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { isHovered = h } }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
    }
}

// MARK: - Sidecar banner (shown inside the island, above nav)

struct SidecarSuggestionBanner: View {
    @ObservedObject private var sidecar = SidecarSuggestionService.shared

    var body: some View {
        if let s = sidecar.active {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
                Text(s.headline)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Button("Enable") {
                    withAnimation(.easeOut(duration: 0.18)) { sidecar.accept() }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(miraTeale)
                .buttonStyle(.plain)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { sidecar.dismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.yellow.opacity(0.08))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
