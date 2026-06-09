import Foundation

// MARK: - Policy Weights

struct PolicyWeights: Codable {
    var causalWeight: Double = 0.60
    var correlationWeight: Double = 0.40
    var categoryMultipliers: [String: Double] = [:]   // learned per-category boosts
    var penaltyMultipliers: [String: Double] = [:]    // from FailureMemory

    func effectiveWeight(for category: String) -> Double {
        let boost = categoryMultipliers[category] ?? 1.0
        let penalty = penaltyMultipliers[category] ?? 1.0
        return boost * penalty
    }
}

// MARK: - Policy Weight Store

@MainActor
final class PolicyWeightStore: ObservableObject {
    static let shared = PolicyWeightStore()

    @Published private(set) var weights: PolicyWeights

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("policy_weights.json")
    }()

    private init() {
        weights = PolicyWeights()
        load()
    }

    // MARK: - Public API

    func adjustCategory(_ category: String, multiplier: Double) {
        weights.categoryMultipliers[category] = multiplier
        save()
    }

    func penalizeCategory(_ category: String, factor: Double) {
        let current = weights.penaltyMultipliers[category] ?? 1.0
        weights.penaltyMultipliers[category] = current * factor
        save()
    }

    func boostCategory(_ category: String, factor: Double) {
        let current = weights.categoryMultipliers[category] ?? 1.0
        weights.categoryMultipliers[category] = current * factor
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(weights) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(PolicyWeights.self, from: data) else { return }
        weights = decoded
    }
}
