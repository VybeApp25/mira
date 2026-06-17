import SwiftUI
import AppKit

// MARK: - KnowledgeImportView
//
// The portable-prompt round-trip UI, usable from Settings and onboarding. For
// EACH assistant the user uses, there's a row to copy that assistant's tailored
// prompt and paste its reply back — imports MERGE, so someone who uses several
// LLMs can build one richer profile from all of them.

struct KnowledgeImportView: View {
    @ObservedObject private var store = UserKnowledgeStore.shared
    @Environment(\.dismiss) private var dismiss
    var embedded: Bool = false
    // When embedded in the island tab, dismiss() is a no-op (there's no sheet) —
    // the host passes a closure to pop back to Settings instead.
    var onClose: (() -> Void)? = nil

    @State private var expanded: KnowledgeProvider?
    @State private var pasteText: [String: String] = [:]
    @State private var status: [String: (ok: Bool, msg: String)] = [:]
    @State private var copied: KnowledgeProvider?

    private let accent = DS.Colors.accent

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        intro
                        profileCard
                        VStack(spacing: 10) {
                            ForEach(KnowledgeProvider.allCases) { providerRow($0) }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: embedded ? nil : 420, height: embedded ? nil : 720)
        // Keep the island open for the whole copy-prompt → paste-reply round-trip:
        // the user must leave Mira (to another assistant) and come back, so the
        // hover auto-collapse must be suspended while this view is on screen.
        .onAppear  { NotificationCenter.default.post(name: .miraPinIsland, object: nil, userInfo: ["pinned": true]) }
        .onDisappear { NotificationCenter.default.post(name: .miraPinIsland, object: nil, userInfo: ["pinned": false]) }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Import Knowledge")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button("Done") { if let onClose { onClose() } else { dismiss() } }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(accent)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var intro: some View {
        Text("Let another AI tell Mira about you. Copy a prompt below, paste it into that assistant, then paste its reply back here. Use as many as you like — they combine into one profile. Nothing is shared with anyone; it stays on this Mac.")
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Current profile

    @ViewBuilder private var profileCard: some View {
        if let k = store.knowledge, !k.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Your profile", systemImage: "person.text.rectangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Button("Clear") { store.clear(); status = [:] }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .buttonStyle(.plain)
                }
                if let summary = k.summary {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text("\(populatedCount(k)) details")
                    if let sources = k.importedFrom, !sources.isEmpty {
                        Text("· from \(sources.joined(separator: ", "))")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
            }
            .padding(12)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Text("No profile imported yet.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    // MARK: Per-provider row

    @ViewBuilder private func providerRow(_ p: KnowledgeProvider) -> some View {
        let isOpen = expanded == p
        let imported = store.knowledge?.importedFrom?.contains(p.displayName) ?? false
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    expanded = isOpen ? nil : p
                }
            } label: {
                HStack(spacing: 10) {
                    Text(p.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    if imported {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green.opacity(0.8))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 11).padding(.horizontal, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { providerBody(p) }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private func providerBody(_ p: KnowledgeProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            stepLabel("1", "Copy this prompt and paste it into \(p.displayName).")
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(KnowledgeImportPrompts.prompt(for: p), forType: .string)
                copied = p
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if copied == p { copied = nil }
                }
            } label: {
                Label(copied == p ? "Copied!" : "Copy \(p.displayName) prompt",
                      systemImage: copied == p ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(copied == p ? .green : accent)
            }
            .buttonStyle(.plain)

            stepLabel("2", "Copy \(p.displayName)'s whole reply, then tap below to load it from your clipboard.")
            Button { loadFromClipboard(p) } label: {
                Label("Paste \(p.displayName)'s reply from clipboard", systemImage: "clipboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)

            // Loaded text is shown read-only for confirmation; editing happens in
            // the source assistant, not here (the island panel can't reliably focus
            // a text field for typing/⌘V — see loadFromClipboard).
            if let loaded = pasteText[p.rawValue], !loaded.isEmpty {
                Text(loaded)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(7)
                    .background(Color.black.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                Button("Import from \(p.displayName)") { runImport(p) }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor((pasteText[p.rawValue]?.isEmpty ?? true) ? .white.opacity(0.25) : accent)
                    .buttonStyle(.plain)
                    .disabled(pasteText[p.rawValue]?.isEmpty ?? true)
                Spacer()
                if let s = status[p.rawValue] {
                    Text(s.msg)
                        .font(.system(size: 11))
                        .foregroundColor(s.ok ? .green : .orange)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 13).padding(.bottom, 13).padding(.top, 2)
    }

    private func stepLabel(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(n)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(accent)
                .frame(width: 16, height: 16)
                .background(Circle().fill(accent.opacity(0.15)))
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Actions

    private func loadFromClipboard(_ p: KnowledgeProvider) {
        let s = NSPasteboard.general.string(forType: .string) ?? ""
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status[p.rawValue] = (false, "Clipboard is empty — copy the reply first.")
        } else {
            pasteText[p.rawValue] = s
            status[p.rawValue] = (true, "Loaded \(s.count) characters. Tap Import.")
        }
    }

    private func runImport(_ p: KnowledgeProvider) {
        let text = pasteText[p.rawValue] ?? ""
        do {
            let merged = try store.importPasted(text, from: p)
            status[p.rawValue] = (true, "Imported · \(populatedCount(merged)) details total")
            pasteText[p.rawValue] = ""
        } catch {
            status[p.rawValue] = (false, error.localizedDescription)
        }
    }

    private func populatedCount(_ k: UserKnowledge) -> Int {
        let arrays = [k.identity, k.work, k.projects, k.goals, k.communicationPreferences,
                      k.expertise, k.toolsAndStack, k.workflows, k.interests, k.preferences,
                      k.constraints, k.decisionStyle, k.keyPeople, k.currentFocus, k.notes]
        return arrays.reduce(0) { $0 + ($1?.count ?? 0) }
    }
}
