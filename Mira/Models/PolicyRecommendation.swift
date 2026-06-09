import Foundation

// MARK: - Policy Recommendation

struct PolicyRecommendation: Identifiable {
    let id: UUID
    let category: String
    let categoryIcon: String
    let expectedImpact: Double         // weighted combination of causal + correlation signal
    let confidence: InsightConfidence
    let rationale: String              // human-readable: why this is recommended
    let priority: Int                  // 1 = highest priority
    let baselineTier: BaselineTier?    // context this recommendation applies to
    let causalEffect: Double?          // from CausalInsight if available
    let correlationEffect: Double      // from CorrelationInsight
}

// MARK: - Policy Decision (audit trail)

struct PolicyDecision: Codable {
    let jobId: UUID
    let recommendations: [String]   // category names recommended
    let decidedAt: Date
    let rationale: String
}
