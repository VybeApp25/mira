// ConversationStore.swift
// Persists Mira conversation history to Application Support/Mira/conversations.json.
// Keeps the last 100 messages; older entries are dropped on save.

import Foundation

final class ConversationStore: ObservableObject {

    static let shared = ConversationStore()

    struct Entry: Codable, Identifiable {
        let id:        UUID
        let role:      String   // "user" | "mira"
        let text:      String
        let timestamp: Date
    }

    @Published private(set) var entries: [Entry] = []

    private let maxCount = 100
    private let encoder  = JSONEncoder()
    private let decoder  = JSONDecoder()

    // MARK: - Public API

    func save(role: String, text: String) {
        // Streaming finalize + transcript-done can both report the same
        // message — an identical consecutive entry is always a double-save.
        if let last = entries.last, last.role == role, last.text == text { return }
        let entry = Entry(id: UUID(), role: role, text: text, timestamp: Date())
        entries.append(entry)
        if entries.count > maxCount {
            entries.removeFirst(entries.count - maxCount)
        }
        persist()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Init

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode([Entry].self, from: data) else { return }
        entries = Array(decoded.suffix(maxCount))
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }
}
