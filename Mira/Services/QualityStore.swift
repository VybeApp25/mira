import Foundation

struct BuildRecord: Codable {
    let id: UUID
    let genre: String
    let prompt: String
    let rating: Int
    let htmlPath: String
    let designStyle: String
    let date: Date
}

final class QualityStore {
    static let shared = QualityStore()

    private let storePath: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quality-store.json")
    }()

    private var records: [BuildRecord] = []

    private init() { load() }

    func record(job: AgentJob, rating: Int) {
        guard let outputPath = job.result?.outputPath,
              let genre = job.result?.metadata["genre"],
              let style = job.result?.metadata["designStyle"] else { return }

        let entry = BuildRecord(
            id: job.id, genre: genre, prompt: job.prompt,
            rating: rating, htmlPath: outputPath, designStyle: style, date: Date()
        )
        records.append(entry)
        save()

        if rating == 5, let html = try? String(contentsOfFile: outputPath, encoding: .utf8) {
            WebsiteBuilderAgent.saveGenreExample(html: html, genre: genre)
        }
    }

    func topStylesForGenre(_ genre: String, limit: Int = 3) -> [String] {
        records
            .filter { $0.genre == genre && $0.rating >= 4 }
            .sorted { $0.rating > $1.rating }
            .prefix(limit)
            .map(\.designStyle)
    }

    func rating(for jobId: UUID) -> Int {
        records.first { $0.id == jobId }?.rating ?? 0
    }

    func successfulPromptsForGenre(_ genre: String) -> [String] {
        records
            .filter { $0.genre == genre && $0.rating >= 4 }
            .sorted { $0.date > $1.date }
            .prefix(5)
            .map(\.prompt)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storePath, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storePath),
              let decoded = try? JSONDecoder().decode([BuildRecord].self, from: data) else { return }
        records = decoded
    }
}
