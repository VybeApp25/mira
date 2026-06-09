import Foundation

// MARK: - Workspace Review

struct WorkspaceReview: Codable, Identifiable {
    let id: UUID
    let generatedAt: Date
    let periodDays: Int

    // Activity stats
    let websitesCreated: Int
    let websitesPublished: Int
    let improvementsRun: Int
    let totalVersions: Int
    let restoreEvents: Int

    // Critic score averages (nil when no critic data exists)
    let avgVisualQuality: Double?
    let avgConversionScore: Double?
    let avgMobileScore: Double?
    let avgAccessibilityScore: Double?

    // Preference patterns (top confidence)
    let topPatterns: [String]

    // Claude synthesis
    let insights: [String]
    let recommendations: [String]
    let suggestedProfile: [String]

    var periodLabel: String {
        "Last \(periodDays) days"
    }

    var overallScoreLabel: String? {
        guard let v = avgVisualQuality,
              let c = avgConversionScore,
              let m = avgMobileScore,
              let a = avgAccessibilityScore else { return nil }
        let avg = (v + c + m + a) / 4
        return String(format: "%.1f", avg)
    }

    var relativeTime: String {
        let diff = Date().timeIntervalSince(generatedAt)
        if diff < 3600  { return "just now" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }
}

// MARK: - Review Store

@MainActor
final class ReviewStore: ObservableObject {
    static let shared = ReviewStore()

    @Published private(set) var reviews: [WorkspaceReview] = []

    private let storePath: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspace-reviews.json")
    }()

    private init() { load() }

    var latest: WorkspaceReview? { reviews.first }

    func save(review: WorkspaceReview) {
        reviews.insert(review, at: 0)
        if reviews.count > 8 { reviews = Array(reviews.prefix(8)) }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storePath),
              let decoded = try? JSONDecoder().decode([WorkspaceReview].self, from: data) else { return }
        reviews = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reviews) else { return }
        try? data.write(to: storePath, options: .atomic)
    }
}
