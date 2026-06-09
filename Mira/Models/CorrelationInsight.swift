import Foundation

// MARK: - Baseline Tier

enum BaselineTier: String, CaseIterable {
    case low    = "Low baseline"
    case medium = "Mid baseline"
    case high   = "High baseline"

    static func classify(_ score: Double) -> BaselineTier {
        if score < 60 { return .low }
        if score < 80 { return .medium }
        return .high
    }

    var range: String {
        switch self {
        case .low:    return "<60"
        case .medium: return "60–80"
        case .high:   return ">80"
        }
    }
}

// MARK: - Confidence

enum InsightConfidence: String {
    case low    = "Low"
    case medium = "Medium"
    case high   = "High"

    var icon: String {
        switch self {
        case .low:    return "circle.dashed"
        case .medium: return "circle.fill"
        case .high:   return "checkmark.shield.fill"
        }
    }
}

// MARK: - Correlation Insight

struct CorrelationInsight: Identifiable {
    let id = UUID()
    let category: String
    let categoryIcon: String
    let totalSampleCount: Int
    let isolatedSampleCount: Int        // runs where only this category was detected
    let avgConversionDelta: Double
    let avgVisualDelta: Double
    let avgOverallDelta: Double
    let confidence: InsightConfidence
    let baselineTier: BaselineTier?     // nil = aggregate across all tiers
    let genre: String?                  // most common genre in this group

    var formattedImpact: String {
        let lead = leadDimension
        let sign = lead.delta >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", lead.delta)) \(lead.label)"
    }

    var leadDimension: (label: String, delta: Double) {
        let candidates: [(String, Double)] = [
            ("conversion", avgConversionDelta),
            ("visual", avgVisualDelta),
            ("overall", avgOverallDelta),
        ]
        return candidates.max(by: { abs($0.1) < abs($1.1) }) ?? ("overall", avgOverallDelta)
    }

    var contextLabel: String {
        if let tier = baselineTier {
            return "\(totalSampleCount) at \(tier.range) baseline"
        }
        return "\(totalSampleCount) improvement\(totalSampleCount == 1 ? "" : "s")"
    }

    var isConditioned: Bool { baselineTier != nil }
}
