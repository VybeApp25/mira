import Foundation

// MARK: - Control Group Record

struct ControlGroupRecord: Codable, Identifiable {
    let id: UUID
    let jobId: UUID
    let appliedCategories: [String]    // categories detected in this run
    let overallDelta: Double
    let conversionDelta: Double
    let visualDelta: Double
    let baseline: Double
    let genre: String
    let recordedAt: Date
}

// MARK: - Control Group Tracker

@MainActor
final class ControlGroupTracker: ObservableObject {
    static let shared = ControlGroupTracker()

    @Published private(set) var records: [ControlGroupRecord] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("control_group.json")
    }()

    private init() { load() }

    // MARK: - Public API

    /// Call this when a websiteImprovement job completes.
    func record(job: AgentJob, appliedCategories: [String]) {
        guard let outcome = ImprovementOutcome(job: job) else { return }

        let preKeys = ["preVisual", "preConversion", "preMobile", "preAccessibility", "preBrand"]
        let preScores = preKeys.compactMap { job.result?.metadata[$0].flatMap(Double.init) }
        let baseline = preScores.isEmpty ? 65.0 : preScores.reduce(0, +) / Double(preScores.count)
        let genre = job.result?.metadata["genre"] ?? "general"

        let rec = ControlGroupRecord(
            id: UUID(),
            jobId: job.id,
            appliedCategories: appliedCategories,
            overallDelta: outcome.averageDelta,
            conversionDelta: outcome.conversionDelta,
            visualDelta: outcome.visualDelta,
            baseline: baseline,
            genre: genre,
            recordedAt: Date()
        )

        // Deduplicate by jobId
        records.removeAll { $0.jobId == job.id }
        records.append(rec)
        save()
    }

    /// Returns records where the given category was NOT applied.
    func controlRecords(for category: String) -> [ControlGroupRecord] {
        records.filter { !$0.appliedCategories.contains(category) }
    }

    /// Returns avg overall delta of control group for a category, optionally filtered by baseline tier.
    func controlGroupDelta(for category: String, baselineTier: BaselineTier? = nil) -> Double? {
        var pool = controlRecords(for: category)
        if let tier = baselineTier {
            pool = pool.filter { BaselineTier.classify($0.baseline) == tier }
        }
        guard !pool.isEmpty else { return nil }
        return pool.map(\.overallDelta).reduce(0, +) / Double(pool.count)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ControlGroupRecord].self, from: data) else { return }
        records = decoded
    }
}
