// MemoryStore.swift
// Mira's long-term memory: explicit preferences + observed patterns with confidence scores.
//
// Explicit memories  → confidence 0.95 (user directly stated)
// Observed memories  → confidence 0.40–0.70 (inferred from behavior)
// Confidence decays  → −0.01/day without reinforcement, floor 0.10
// Reinforcement      → +0.08 when confirmed/re-stated, cap 1.0
// Conflict           → new value replaces old when confidence ≥ existing − 0.1

import Foundation

// MARK: - Model

struct Memory: Codable, Identifiable {
    let id:           UUID
    var key:          String       // snake_case, e.g. "preferred_browser"
    var value:        String       // human-readable value, e.g. "Safari"
    var category:     Category
    var source:       Source
    var confidence:   Double       // 0.0 – 1.0
    var notes:        String?      // optional supporting context
    let createdAt:    Date
    var updatedAt:    Date
    var accessCount:  Int

    enum Category: String, Codable, CaseIterable {
        case preference = "preference"
        case project    = "project"
        case person     = "person"
        case fact       = "fact"
        case goal       = "goal"

        var icon: String {
            switch self {
            case .preference: return "slider.horizontal.3"
            case .project:    return "folder.fill"
            case .person:     return "person.fill"
            case .fact:       return "info.circle.fill"
            case .goal:       return "target"
            }
        }
    }

    enum Source: String, Codable {
        case explicit   // user stated directly ("I prefer Safari")
        case observed   // inferred from repeated behavior
    }

    var confidenceTier: Tier {
        if confidence >= 0.8 { return .high }
        if confidence >= 0.5 { return .medium }
        return .low
    }

    enum Tier { case high, medium, low }
}

// MARK: - Store

@MainActor
final class MemoryStore: ObservableObject {

    static let shared = MemoryStore()

    @Published private(set) var memories: [Memory] = []

    // MARK: - Public API

    /// Upsert a memory. If a matching key already exists, updates value and boosts confidence.
    @discardableResult
    func upsert(key: String,
                value: String,
                category: Memory.Category = .fact,
                source: Memory.Source = .explicit,
                confidence: Double = 0.95,
                notes: String? = nil) -> Memory {
        let normKey = key.lowercased().trimmingCharacters(in: .whitespaces)

        if let idx = memories.firstIndex(where: { $0.key.lowercased() == normKey }) {
            memories[idx].value       = value
            memories[idx].notes       = notes ?? memories[idx].notes
            memories[idx].updatedAt   = Date()
            memories[idx].accessCount += 1
            memories[idx].confidence  = min(1.0, max(confidence,
                                                      memories[idx].confidence + 0.08))
            persist()
            return memories[idx]
        }

        let mem = Memory(id: UUID(), key: key, value: value,
                         category: category, source: source,
                         confidence: confidence, notes: notes,
                         createdAt: Date(), updatedAt: Date(), accessCount: 1)
        memories.append(mem)
        persist()
        return mem
    }

    /// Fuzzy search memories by key or value substring.
    func recall(query: String) -> [Memory] {
        let q = query.lowercased()
        return memories
            .filter { $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
            .sorted { $0.confidence > $1.confidence }
    }

    func memory(forKey key: String) -> Memory? {
        memories.first { $0.key.lowercased() == key.lowercased() }
    }

    func delete(id: UUID) {
        memories.removeAll { $0.id == id }
        persist()
    }

    func delete(key: String) {
        memories.removeAll { $0.key.lowercased() == key.lowercased() }
        persist()
    }

    func clear() {
        memories = []
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Bumps confidence when a memory is confirmed or referenced.
    func reinforce(key: String) {
        guard let idx = memories.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) else { return }
        memories[idx].confidence  = min(1.0, memories[idx].confidence + 0.08)
        memories[idx].accessCount += 1
        memories[idx].updatedAt   = Date()
        persist()
    }

    /// Applies daily decay to all memories. Call once per app launch.
    func applyDecay() {
        let now        = Date()
        let daySeconds = 86_400.0
        var changed    = false
        for idx in memories.indices {
            let days  = now.timeIntervalSince(memories[idx].updatedAt) / daySeconds
            let decay = days * 0.01
            if decay > 0.001 {
                memories[idx].confidence = max(0.1, memories[idx].confidence - decay)
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: - Prompt block (injected into session instructions)

    /// Returns the top memories formatted for the system prompt.
    /// Only includes memories with confidence ≥ 0.5 to avoid injecting uncertain guesses.
    func buildPromptBlock() -> String {
        let relevant = memories
            .filter { $0.confidence >= 0.5 }
            .sorted { $0.confidence > $1.confidence }
            .prefix(12)

        guard !relevant.isEmpty else { return "" }

        var lines = ["[What I know about you]"]
        for mem in relevant {
            let qualifier: String = {
                switch mem.confidenceTier {
                case .high:   return ""
                case .medium: return " (probably)"
                case .low:    return " (uncertain)"
                }
            }()
            lines.append("\(mem.key): \(mem.value)\(qualifier)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private init() {
        load()
        applyDecay()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Memory].self, from: data) else { return }
        memories = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(memories) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }
}
