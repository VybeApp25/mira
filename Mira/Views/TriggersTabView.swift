// TriggersTabView.swift
// Phase 17 — UI for managing external triggers (file watch, webhooks, GitHub).

import SwiftUI

private let cardBG  = Color(red: 0.11, green: 0.11, blue: 0.14)
private let accent  = DS.Colors.accent
private let amber   = Color(red: 1.0,  green: 0.75, blue: 0.20)
private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)

struct TriggersTabView: View {
    @ObservedObject private var store   = TriggerStore.shared
    @ObservedObject private var server  = WebhookServer.shared
    @ObservedObject private var engine  = ProjectEngine.shared
    @State private var showingCreate    = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if server.isRunning {
                webhookStatusBanner
            }

            if store.triggers.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(store.triggers) { trigger in
                            TriggerRow(trigger: trigger, engine: engine)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
        }
        .sheet(isPresented: $showingCreate) {
            TriggerEditorView(engine: engine)
        }
    }

    private var header: some View {
        HStack {
            Text("External Triggers")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Button { showingCreate = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var webhookStatusBanner: some View {
        HStack(spacing: 6) {
            Circle().fill(successG).frame(width: 6, height: 6)
            Text("Listening on port \(server.port)")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.50))
            if let label = server.lastEventLabel {
                Text("· \(label)")
                    .font(.system(size: 10))
                    .foregroundColor(accent.opacity(0.70))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.15))
            Text("No triggers yet")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.30))
            Text("Watch files or receive webhooks to auto-resume projects.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.18))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
    }
}

// MARK: - Trigger row

private struct TriggerRow: View {
    let trigger: ExternalTrigger
    let engine:  ProjectEngine
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(kindColor.opacity(0.14)).frame(width: 28, height: 28)
                Image(systemName: trigger.kind.icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(kindColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(trigger.kind.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.38))
                        .lineLimit(1)
                    if let proj = engine.project(id: trigger.projectId ?? UUID()) {
                        Text("→ \(proj.name)")
                            .font(.system(size: 10))
                            .foregroundColor(accent.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                if let summary = trigger.lastEventSummary {
                    Text(summary)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.24))
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Toggle("", isOn: Binding(
                    get: { trigger.enabled },
                    set: { _ in TriggerStore.shared.toggle(id: trigger.id) }
                ))
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .frame(width: 36)

                if let firedAt = trigger.lastFiredAt {
                    Text(relativeTime(firedAt))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.22))
                }
            }

            Button {
                TriggerStore.shared.delete(id: trigger.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.20))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(cardBG)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(trigger.enabled ? 1.0 : 0.50)
    }

    private var kindColor: Color {
        switch trigger.kind {
        case .fileChange: return accent
        case .webhook:    return amber
        case .githubPush: return successG
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60     { return "just now" }
        if diff < 3_600  { return "\(Int(diff / 60))m ago" }
        if diff < 86_400 { return "\(Int(diff / 3_600))h ago" }
        return "\(Int(diff / 86_400))d ago"
    }
}

// MARK: - Trigger editor

struct TriggerEditorView: View {
    let engine: ProjectEngine
    @Environment(\.dismiss) private var dismiss

    @State private var name        = ""
    @State private var kind: TriggerKindOption = .fileChange
    @State private var filePath    = ""
    @State private var webhookSecret = ""
    @State private var githubRepo  = ""
    @State private var githubBranch = "main"
    @State private var githubSecret = ""
    @State private var projectId: UUID? = nil
    @State private var prompt      = ""

    enum TriggerKindOption: String, CaseIterable, Identifiable {
        case fileChange = "File Watch"
        case webhook    = "Webhook"
        case githubPush = "GitHub Push"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Trigger")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            field("Name", text: $name, placeholder: "My trigger")

            Picker("Kind", selection: $kind) {
                ForEach(TriggerKindOption.allCases) { k in
                    Text(k.rawValue).tag(k)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch kind {
                case .fileChange:
                    field("File or directory path", text: $filePath, placeholder: "/path/to/file")
                case .webhook:
                    field("Shared secret (optional)", text: $webhookSecret, placeholder: "leave blank to skip verification")
                case .githubPush:
                    field("Repository (owner/name)", text: $githubRepo, placeholder: "myorg/myrepo")
                    field("Branch", text: $githubBranch, placeholder: "main")
                    field("Webhook secret (optional)", text: $githubSecret, placeholder: "from GitHub webhook settings")
                }
            }

            // Project link
            let candidates = engine.projects.filter { $0.status != .archived }
            if !candidates.isEmpty {
                Picker("Resume project", selection: $projectId) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(candidates) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: 11))
                .tint(.white.opacity(0.65))
            }

            // Optional prompt
            VStack(alignment: .leading, spacing: 4) {
                Text("Run prompt on fire (optional)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                TextEditor(text: $prompt)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(height: 60)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.40))
                Spacer()
                Button("Add Trigger") { save() }
                    .disabled(!isValid)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isValid ? accent : .white.opacity(0.20))
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        (kind != .fileChange || !filePath.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func save() {
        let trimName = name.trimmingCharacters(in: .whitespaces)
        let triggerKind: TriggerKind
        switch kind {
        case .fileChange:
            triggerKind = .fileChange(path: filePath.trimmingCharacters(in: .whitespaces))
        case .webhook:
            let s = webhookSecret.trimmingCharacters(in: .whitespaces)
            triggerKind = .webhook(secret: s.isEmpty ? nil : s)
        case .githubPush:
            let s = githubSecret.trimmingCharacters(in: .whitespaces)
            triggerKind = .githubPush(
                repo: githubRepo.trimmingCharacters(in: .whitespaces),
                branch: githubBranch.trimmingCharacters(in: .whitespaces),
                secret: s.isEmpty ? nil : s
            )
        }
        let promptTrimmed = prompt.trimmingCharacters(in: .whitespaces)
        let trigger = ExternalTrigger(
            name: trimName,
            kind: triggerKind,
            projectId: projectId,
            prompt: promptTrimmed.isEmpty ? nil : promptTrimmed
        )
        TriggerStore.shared.add(trigger)
        dismiss()
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
