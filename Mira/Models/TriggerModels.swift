// TriggerModels.swift
// Phase 17 — External trigger model + persistent store.
// Three trigger kinds: file-system watch, generic webhook, GitHub push webhook.

import Foundation

// MARK: - TriggerKind

enum TriggerKind: Codable, Equatable, Hashable {
    case fileChange(path: String)
    case webhook(secret: String?)
    case githubPush(repo: String, branch: String, secret: String?)

    var displayName: String {
        switch self {
        case .fileChange(let p):
            return URL(fileURLWithPath: p).lastPathComponent
        case .webhook:
            return "Webhook (any POST)"
        case .githubPush(let repo, let branch, _):
            return branch.isEmpty ? "GitHub: \(repo)" : "GitHub: \(repo) [\(branch)]"
        }
    }

    var icon: String {
        switch self {
        case .fileChange: return "doc.badge.clock.fill"
        case .webhook:    return "arrow.down.circle.fill"
        case .githubPush: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - ExternalTrigger

struct ExternalTrigger: Identifiable, Codable {
    let id:                 UUID
    var name:               String
    var kind:               TriggerKind
    /// Linked project to resume on fire. nil = notification only.
    var projectId:          UUID?
    /// Optional Claude prompt to run on fire.
    var prompt:             String?
    var enabled:            Bool
    var lastFiredAt:        Date?
    var lastEventSummary:   String?
    let createdAt:          Date

    init(name: String, kind: TriggerKind, projectId: UUID? = nil, prompt: String? = nil) {
        self.id        = UUID()
        self.name      = name
        self.kind      = kind
        self.projectId = projectId
        self.prompt    = prompt
        self.enabled   = true
        self.createdAt = Date()
    }
}

// MARK: - TriggerStore

@MainActor
final class TriggerStore: ObservableObject {
    static let shared = TriggerStore()

    @Published private(set) var triggers: [ExternalTrigger] = []

    private let storeKey = "mira_external_triggers_v1"
    private init() { load() }

    func add(_ trigger: ExternalTrigger) {
        triggers.append(trigger)
        save()
        ExternalTriggerRunner.shared.rebuildWatchers()
    }

    func update(_ trigger: ExternalTrigger) {
        guard let idx = triggers.firstIndex(where: { $0.id == trigger.id }) else { return }
        triggers[idx] = trigger
        save()
        ExternalTriggerRunner.shared.rebuildWatchers()
    }

    func delete(id: UUID) {
        triggers.removeAll { $0.id == id }
        save()
        ExternalTriggerRunner.shared.rebuildWatchers()
    }

    func toggle(id: UUID) {
        guard let idx = triggers.firstIndex(where: { $0.id == id }) else { return }
        triggers[idx].enabled.toggle()
        save()
        ExternalTriggerRunner.shared.rebuildWatchers()
    }

    func recordFired(id: UUID, summary: String) {
        guard let idx = triggers.firstIndex(where: { $0.id == id }) else { return }
        triggers[idx].lastFiredAt      = Date()
        triggers[idx].lastEventSummary = summary
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(triggers) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func load() {
        guard let data   = UserDefaults.standard.data(forKey: storeKey),
              let stored = try? JSONDecoder().decode([ExternalTrigger].self, from: data) else { return }
        triggers = stored
    }
}
