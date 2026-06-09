import Foundation

// MARK: - Causal Insight
//
// Represents a Difference-in-Differences estimate of a category's causal effect.
// treatedAvgDelta = avg outcome when the category WAS applied
// controlAvgDelta = avg outcome when the category was NOT applied
// causalEffect    = treatedAvgDelta - controlAvgDelta

struct CausalInsight: Identifiable {
    let id = UUID()
    let category: String
    let categoryIcon: String
    let treatedAvgDelta: Double       // avg delta when this category WAS applied (attributed)
    let controlAvgDelta: Double       // avg delta when this category was NOT applied
    let causalEffect: Double          // treatedAvgDelta - controlAvgDelta (the DiD estimate)
    let treatedCount: Int
    let controlCount: Int
    let confidence: InsightConfidence
    let baselineTier: BaselineTier?

    var formattedCausalEffect: String {
        let sign = causalEffect >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", causalEffect)) causal effect"
    }

    var isStatisticallyMeaningful: Bool {
        treatedCount >= 2 && controlCount >= 2
    }
}
