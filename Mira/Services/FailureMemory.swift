import Foundation

// MARK: - Failure Memory
//
// Records prediction failures per category, enabling the PolicyEngine to
// deprioritize categories with high historic prediction error.

@MainActor
final class FailureMemory: ObservableObject {
    static let shared = FailureMemory()

    @Published private(set) var records: [FailureRecord] = []

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("failure_memory.json")
    }()

    private init() { load() }

    // MARK: - Public API

    func record(category: String, predicted: Double, actual: Double) {
        let error = actual - predicted
        let failureType: FailureType = error < 0 ? .overestimated : .underestimated

        let rec = FailureRecord(
            id: UUID(),
            category: category,
            predictedImpact: predicted,
            actualImpact: actual,
            errorDelta: error,
            failureType: failureType,
            timestamp: Date()
        )

        records.append(rec)
        // Keep bounded — last 1000 records
        if records.count > 1000 {
            records = Array(records.suffix(1000))
        }
        save()
    }

    /// Returns failure rate for a category (fraction of records that are overestimations).
    func failureRate(for category: String) -> Double {
        let categoryRecords = records.filter { $0.category == category }
        guard !categoryRecords.isEmpty else { return 0 }
        let failures = categoryRecords.filter { $0.failureType == .overestimated }.count
        return Double(failures) / Double(categoryRecords.count)
    }

    /// Returns average absolute error magnitude for a category.
    func avgError(for category: String) -> Double {
        let categoryRecords = records.filter { $0.category == category }
        guard !categoryRecords.isEmpty else { return 0 }
        return categoryRecords.map { abs($0.errorDelta) }.reduce(0, +) / Double(categoryRecords.count)
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([FailureRecord].self, from: data) else { return }
        records = decoded
    }
}
