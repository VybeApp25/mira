import Foundation

// MARK: - Policy Engine
//
// Generates ranked category recommendations by blending:
//   - Causal effects (DiD estimates from CausalEngine)
//   - Correlation effects (from CorrelationEngine)
//   - Learned weights (from PolicyWeightStore)

@MainActor
final class PolicyEngine: ObservableObject {
    static let shared = PolicyEngine()

    @Published private(set) var recommendations: [PolicyRecommendation] = []
    @Published private(set) var decisionLog: [PolicyDecision] = []

    private init() {}

    // MARK: - Entry-specific recommendations (used by WebsiteImprovementAgent)

    func recommend(for entryId: UUID, jobs: [AgentJob]) -> [PolicyRecommendation] {
        let causalInsights = CausalEngine.compute(from: jobs, tracker: ControlGroupTracker.shared)
        let correlationInsights = CorrelationEngine.compute(from: jobs)
        let weightStore = PolicyWeightStore.shared

        // Determine baseline tier from the most recent critic report for this entry
        let entryJobs = jobs.filter { $0.editSourceEntryId == entryId && $0.type == .websiteImprovement && $0.status == .completed }
        let baseline = entryJobs.compactMap { job -> Double? in
            let preKeys = ["preVisual", "preConversion", "preMobile", "preAccessibility", "preBrand"]
            let scores = preKeys.compactMap { job.result?.metadata[$0].flatMap(Double.init) }
            return scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        }.last
        let baselineTier = baseline.map { BaselineTier.classify($0) }

        return buildRecommendations(
            causalInsights: causalInsights,
            correlationInsights: correlationInsights,
            weightStore: weightStore,
            baselineTier: baselineTier
        )
    }

    // MARK: - General recommendations (used by WorkspaceDashboardView)

    func recommendGeneral(jobs: [AgentJob]) -> [PolicyRecommendation] {
        let causalInsights = CausalEngine.compute(from: jobs, tracker: ControlGroupTracker.shared)
        let correlationInsights = CorrelationEngine.compute(from: jobs)
        let weightStore = PolicyWeightStore.shared

        return buildRecommendations(
            causalInsights: causalInsights,
            correlationInsights: correlationInsights,
            weightStore: weightStore,
            baselineTier: nil
        )
    }

    // MARK: - Log a policy decision

    func logDecision(jobId: UUID, recommendedCategories: [String], rationale: String) {
        let decision = PolicyDecision(
            jobId: jobId,
            recommendations: recommendedCategories,
            decidedAt: Date(),
            rationale: rationale
        )
        decisionLog.append(decision)
        // Keep log bounded
        if decisionLog.count > 500 {
            decisionLog = Array(decisionLog.suffix(500))
        }
    }

    // MARK: - Refresh published recommendations

    func refresh(jobs: [AgentJob]) {
        recommendations = recommendGeneral(jobs: jobs)
        AttentionEngine.shared.update(from: recommendations)
    }

    // MARK: - Core Builder

    private func buildRecommendations(
        causalInsights: [CausalInsight],
        correlationInsights: [CorrelationInsight],
        weightStore: PolicyWeightStore,
        baselineTier: BaselineTier?
    ) -> [PolicyRecommendation] {

        // Gather all category names from both engines
        let allCategories = Set(causalInsights.map(\.category))
            .union(Set(correlationInsights.map(\.category)))

        var recs: [PolicyRecommendation] = []

        for (priority, category) in allCategories.sorted().enumerated() {
            let causal = causalInsights.first(where: { $0.category == category })
            let corr = correlationInsights.filter { !$0.isConditioned }.first(where: { $0.category == category })
            ?? correlationInsights.first(where: { $0.category == category })

            // Need at least one signal
            guard causal != nil || corr != nil else { continue }

            let correlationEffect = corr?.avgOverallDelta ?? 0.0
            let weights = weightStore.weights

            let rawExpected: Double
            if let c = causal {
                rawExpected = weights.causalWeight * c.causalEffect + weights.correlationWeight * correlationEffect
            } else {
                rawExpected = correlationEffect
            }

            let effectiveMultiplier = weightStore.weights.effectiveWeight(for: category)
            let expectedImpact = rawExpected * effectiveMultiplier

            // Confidence is the better of the two signals
            let confidence: InsightConfidence
            if let c = causal {
                switch (c.confidence, corr?.confidence) {
                case (.high, _): confidence = .high
                case (.medium, .high): confidence = .high
                case (.medium, _): confidence = .medium
                default: confidence = .low
                }
            } else {
                confidence = corr?.confidence ?? .low
            }

            // Generate rationale
            let rationale = buildRationale(
                category: category,
                causal: causal,
                correlation: corr,
                expectedImpact: expectedImpact
            )

            let rec = PolicyRecommendation(
                id: UUID(),
                category: category,
                categoryIcon: iconForCategory(category),
                expectedImpact: expectedImpact,
                confidence: confidence,
                rationale: rationale,
                priority: priority + 1,
                baselineTier: baselineTier,
                causalEffect: causal?.causalEffect,
                correlationEffect: correlationEffect
            )
            recs.append(rec)
        }

        // Sort by expectedImpact DESC
        return recs
            .sorted { $0.expectedImpact > $1.expectedImpact }
            .enumerated()
            .map { idx, rec in
                // Re-rank priorities after sorting
                PolicyRecommendation(
                    id: rec.id,
                    category: rec.category,
                    categoryIcon: rec.categoryIcon,
                    expectedImpact: rec.expectedImpact,
                    confidence: rec.confidence,
                    rationale: rec.rationale,
                    priority: idx + 1,
                    baselineTier: rec.baselineTier,
                    causalEffect: rec.causalEffect,
                    correlationEffect: rec.correlationEffect
                )
            }
    }

    // MARK: - Rationale Generator

    private func buildRationale(
        category: String,
        causal: CausalInsight?,
        correlation: CorrelationInsight?,
        expectedImpact: Double
    ) -> String {
        if let c = causal, c.isStatisticallyMeaningful {
            let sign = c.causalEffect >= 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", c.causalEffect)) pts causal effect across \(c.treatedCount) treatments vs \(c.controlCount) controls"
        } else if let corr = correlation {
            let sign = corr.avgOverallDelta >= 0 ? "+" : ""
            return "\(sign)\(String(format: "%.1f", corr.avgOverallDelta)) pts correlation from \(corr.totalSampleCount) similar improvements"
        }
        return "Expected \(String(format: "%.1f", expectedImpact)) pts impact based on historical data"
    }

    // MARK: - Icon mapping

    private func iconForCategory(_ category: String) -> String {
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
