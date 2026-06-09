import Foundation

// MARK: - Causal Engine
//
// Computes Difference-in-Differences causal effect estimates by comparing:
//   - Treated group: runs where a given category WAS detected/applied
//   - Control group: runs where the category was NOT applied (from ControlGroupTracker)
//
// Requires treatedCount >= 2 AND controlCount >= 2 before surfacing an insight.

@MainActor
final class CausalEngine {

    static func compute(from jobs: [AgentJob], tracker: ControlGroupTracker) -> [CausalInsight] {
        // Build attributed run deltas per category from completed improvement jobs
        var treatedDeltas: [String: [Double]] = [:]

        for job in jobs where job.type == .websiteImprovement && job.status == .completed {
            guard let outcome = ImprovementOutcome(job: job) else { continue }
            let text = [job.result?.summary, job.prompt].compactMap { $0 }.joined(separator: " ")
            let categories = CorrelationEngine.detectAllCategories(from: text)
            for category in categories {
                treatedDeltas[category, default: []].append(outcome.averageDelta)
            }
        }

        var insights: [CausalInsight] = []

        for (category, deltas) in treatedDeltas {
            let controlRecords = tracker.controlRecords(for: category)
            guard deltas.count >= 2, controlRecords.count >= 2 else { continue }

            let treatedAvg = deltas.reduce(0, +) / Double(deltas.count)
            let controlAvg = controlRecords.map(\.overallDelta).reduce(0, +) / Double(controlRecords.count)
            let causalEffect = treatedAvg - controlAvg

            let minCount = min(deltas.count, controlRecords.count)
            let confidence: InsightConfidence
            if minCount >= 5 { confidence = .high }
            else if minCount >= 3 { confidence = .medium }
            else { confidence = .low }

            let insight = CausalInsight(
                category: category,
                categoryIcon: iconForCategory(category),
                treatedAvgDelta: treatedAvg,
                controlAvgDelta: controlAvg,
                causalEffect: causalEffect,
                treatedCount: deltas.count,
                controlCount: controlRecords.count,
                confidence: confidence,
                baselineTier: nil
            )
            insights.append(insight)
        }

        return insights
            .filter(\.isStatisticallyMeaningful)
            .sorted { abs($0.causalEffect) > abs($1.causalEffect) }
    }

    // MARK: - Icon mapping (mirrors CorrelationEngine)

    private static func iconForCategory(_ category: String) -> String {
        switch category {
        case "Testimonials":  return "quote.bubble.fill"
        case "Hero Section":  return "rectangle.portrait.topthird.inset.filled"
        case "CTA & Buttons": return "hand.tap.fill"
        case "Navigation":    return "list.bullet"
        case "Mobile UX":     return "iphone"
        case "Typography":    return "textformat.size"
        case "Color & Theme": return "paintpalette.fill"
        case "Imagery":       return "photo.fill"
        case "Pricing":       return "tag.fill"
        case "Contact Form":  return "envelope.fill"
        case "Footer":        return "rectangle.bottomthird.inset.filled"
        case "Animations":    return "sparkle"
        default:              return "sparkles"
        }
    }
}
