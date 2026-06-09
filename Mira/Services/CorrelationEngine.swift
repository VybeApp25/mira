import Foundation

// MARK: - Correlation Engine
//
// Three-layer causal fidelity model:
//   Layer 1 — Change Isolation: single-category runs produce clean signal
//   Layer 2 — Multi-label Attribution: delta is split across detected categories by keyword weight
//   Layer 3 — Conditioned Grouping: insights are segmented by site baseline tier
//
// Flat insights (all tiers) are always shown.
// Conditioned insights are surfaced only when a tier differs meaningfully from the flat average.
// Minimum 2 samples required before any insight is surfaced.

@MainActor
final class CorrelationEngine {

    // MARK: - Entry Point

    static func compute(from jobs: [AgentJob]) -> [CorrelationInsight] {
        let runs = buildAttributedRuns(from: jobs)
        guard !runs.isEmpty else { return [] }

        let flat        = buildFlatInsights(from: runs)
        let conditioned = buildConditionedInsights(from: runs, flat: flat)

        return (flat + conditioned)
            .sorted { abs($0.avgOverallDelta) > abs($1.avgOverallDelta) }
    }

    // MARK: - Layer 1 + 2: Attributed Run

    private struct AttributedRun {
        let categoryWeights: [String: Double]   // category → keyword frequency weight
        let totalWeight: Double
        let conversionDelta: Double
        let visualDelta: Double
        let overallDelta: Double
        let baseline: Double
        let genre: String

        var isIsolated: Bool { categoryWeights.count == 1 }

        // Fraction of this run's delta that belongs to one category
        func attributedDelta(for category: String) -> (conversion: Double, visual: Double, overall: Double)? {
            guard let weight = categoryWeights[category], totalWeight > 0 else { return nil }
            let f = weight / totalWeight
            return (conversionDelta * f, visualDelta * f, overallDelta * f)
        }
    }

    private static func buildAttributedRuns(from jobs: [AgentJob]) -> [AttributedRun] {
        jobs.compactMap { job -> AttributedRun? in
            guard let outcome = ImprovementOutcome(job: job) else { return nil }

            let text  = [job.result?.summary, job.prompt].compactMap { $0 }.joined(separator: " ").lowercased()
            let genre = job.result?.metadata["genre"] ?? "general"

            // Baseline: average of all pre-improvement critic scores
            let preKeys = ["preVisual", "preConversion", "preMobile", "preAccessibility", "preBrand"]
            let preScores = preKeys.compactMap { job.result?.metadata[$0].flatMap(Double.init) }
            let baseline  = preScores.isEmpty ? 65.0 : preScores.avg

            // Keyword weight per category — measures how prominently each category features
            var weights: [String: Double] = [:]
            for (category, keywords) in Self.categoryKeywords {
                let w = keywords.reduce(0.0) { acc, kw in
                    acc + Double(max(text.components(separatedBy: kw).count - 1, 0))
                }
                if w > 0 { weights[category] = w }
            }
            guard !weights.isEmpty else { return nil }

            return AttributedRun(
                categoryWeights: weights,
                totalWeight: weights.values.reduce(0, +),
                conversionDelta: outcome.conversionDelta,
                visualDelta: outcome.visualDelta,
                overallDelta: outcome.averageDelta,
                baseline: baseline,
                genre: genre
            )
        }
    }

    // MARK: - Shared Sample Type

    private struct CategorySample {
        let conversionDelta: Double
        let visualDelta: Double
        let overallDelta: Double
        let isIsolated: Bool
        let baseline: Double
        let genre: String
    }

    private static func samplesPerCategory(from runs: [AttributedRun]) -> [String: [CategorySample]] {
        var result: [String: [CategorySample]] = [:]
        for run in runs {
            for (category, _) in run.categoryWeights {
                guard let d = run.attributedDelta(for: category) else { continue }
                result[category, default: []].append(CategorySample(
                    conversionDelta: d.conversion,
                    visualDelta: d.visual,
                    overallDelta: d.overall,
                    isIsolated: run.isIsolated,
                    baseline: run.baseline,
                    genre: run.genre
                ))
            }
        }
        return result
    }

    // MARK: - Layer 2: Flat Insights (aggregate across all baseline tiers)

    private static func buildFlatInsights(from runs: [AttributedRun]) -> [CorrelationInsight] {
        samplesPerCategory(from: runs)
            .filter { $0.value.count >= 2 }
            .compactMap { category, samples in
                buildInsight(category: category, samples: samples, tier: nil)
            }
            .sorted { abs($0.avgOverallDelta) > abs($1.avgOverallDelta) }
    }

    // MARK: - Layer 3: Conditioned Grouping

    private static func buildConditionedInsights(from runs: [AttributedRun], flat: [CorrelationInsight]) -> [CorrelationInsight] {
        // Bucket samples by (category, baseline tier)
        var buckets: [String: [BaselineTier: [CategorySample]]] = [:]
        for run in runs {
            let tier = BaselineTier.classify(run.baseline)
            for (category, _) in run.categoryWeights {
                guard let d = run.attributedDelta(for: category) else { continue }
                let sample = CategorySample(
                    conversionDelta: d.conversion, visualDelta: d.visual, overallDelta: d.overall,
                    isIsolated: run.isIsolated, baseline: run.baseline, genre: run.genre
                )
                buckets[category, default: [:]][tier, default: []].append(sample)
            }
        }

        var insights: [CorrelationInsight] = []
        for (category, tierMap) in buckets {
            let flatInsight = flat.first(where: { $0.category == category })
            for (tier, samples) in tierMap where samples.count >= 2 {
                guard let insight = buildInsight(category: category, samples: samples, tier: tier) else { continue }
                // Only surface if this tier differs meaningfully from the flat average
                if hasMeaningfulDifferentiation(conditioned: insight, flat: flatInsight) {
                    insights.append(insight)
                }
            }
        }
        return insights
    }

    // Surface a conditioned insight only when its delta differs from the flat average by >25%
    private static func hasMeaningfulDifferentiation(conditioned: CorrelationInsight, flat: CorrelationInsight?) -> Bool {
        guard let flat = flat else { return true }
        let flatAbs = abs(flat.avgOverallDelta)
        let condAbs = abs(conditioned.avgOverallDelta)
        guard flatAbs > 0 else { return condAbs > 0.5 }
        return abs(condAbs - flatAbs) / flatAbs > 0.25
    }

    // MARK: - Insight Builder

    private static func buildInsight(category: String, samples: [CategorySample], tier: BaselineTier?) -> CorrelationInsight? {
        guard samples.count >= 2 else { return nil }

        let isolatedCount = samples.filter(\.isIsolated).count
        let confidence: InsightConfidence
        if isolatedCount >= 3                         { confidence = .high }
        else if isolatedCount >= 1 && samples.count >= 3 { confidence = .medium }
        else                                          { confidence = .low }

        let topGenre = Dictionary(grouping: samples, by: \.genre)
            .max(by: { $0.value.count < $1.value.count })?.key

        return CorrelationInsight(
            category: category,
            categoryIcon: Self.icon(for: category),
            totalSampleCount: samples.count,
            isolatedSampleCount: isolatedCount,
            avgConversionDelta: samples.map(\.conversionDelta).avg,
            avgVisualDelta: samples.map(\.visualDelta).avg,
            avgOverallDelta: samples.map(\.overallDelta).avg,
            confidence: confidence,
            baselineTier: tier,
            genre: topGenre
        )
    }

    // MARK: - Category Dictionary (shared for detection + weighting)

    private static let categoryKeywords: [String: [String]] = [
        "Testimonials":  ["testimonial", "review", "social proof", "trust signal", "client quote", "customer quote"],
        "Hero Section":  ["hero section", "above the fold", "main banner", "headline section", "hero image"],
        "CTA & Buttons": ["call to action", " cta ", "button copy", "button text", "primary button", "action button"],
        "Navigation":    ["navigation bar", "nav bar", "sticky nav", "header nav", "menu structure"],
        "Mobile UX":     ["mobile layout", "responsive", "breakpoint", "small screen", "mobile experience"],
        "Typography":    ["typography", "font size", "heading size", "font weight", "text hierarchy"],
        "Color & Theme": ["color scheme", "dark mode", "colour palette", "color palette", "contrast ratio"],
        "Imagery":       ["background image", "hero image", "illustration", "photography", "visual asset"],
        "Pricing":       ["pricing section", "pricing table", "pricing plan", "price display"],
        "Contact Form":  ["contact form", "contact section", "inquiry form", "lead form"],
        "Footer":        ["footer section", "footer content", "footer links"],
        "Animations":    ["animation", "scroll effect", "parallax", "micro-interaction", "transition effect"],
    ]

    private static func icon(for category: String) -> String {
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

    // MARK: - Public Detection Helper (used by ControlGroupTracker, CausalEngine)
    // nonisolated is safe because categoryKeywords is a constant (static let).

    nonisolated static func detectAllCategories(from text: String) -> [String] {
        let lower = text.lowercased()
        let keywords: [String: [String]] = [
            "Testimonials":  ["testimonial", "review", "social proof", "trust signal", "client quote", "customer quote"],
            "Hero Section":  ["hero section", "above the fold", "main banner", "headline section", "hero image"],
            "CTA & Buttons": ["call to action", " cta ", "button copy", "button text", "primary button", "action button"],
            "Navigation":    ["navigation bar", "nav bar", "sticky nav", "header nav", "menu structure"],
            "Mobile UX":     ["mobile layout", "responsive", "breakpoint", "small screen", "mobile experience"],
            "Typography":    ["typography", "font size", "heading size", "font weight", "text hierarchy"],
            "Color & Theme": ["color scheme", "dark mode", "colour palette", "color palette", "contrast ratio"],
            "Imagery":       ["background image", "hero image", "illustration", "photography", "visual asset"],
            "Pricing":       ["pricing section", "pricing table", "pricing plan", "price display"],
            "Contact Form":  ["contact form", "contact section", "inquiry form", "lead form"],
            "Footer":        ["footer section", "footer content", "footer links"],
            "Animations":    ["animation", "scroll effect", "parallax", "micro-interaction", "transition effect"],
        ]
        return keywords.keys.filter { category in
            keywords[category]!.contains(where: { lower.contains($0) })
        }
    }
}

// MARK: - Helpers

private extension Array where Element == Double {
    var avg: Double {
        isEmpty ? 0 : reduce(0, +) / Double(count)
    }
}
