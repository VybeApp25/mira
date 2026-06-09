import Foundation

// MARK: - Confidence Tier

enum ConfidenceTier: String {
    case low    = "Low"
    case medium = "Medium"
    case high   = "High"
}

// MARK: - Preference

struct Preference {
    let trait: String
    let score: Double
    let confidence: ConfidenceTier
    let evidenceItems: [String]
}

// MARK: - Preference Profile

struct PreferenceProfile {
    let preferences: [Preference]
    let computedAt: Date
    let dataPointsAnalyzed: Int

    var isEmpty: Bool { preferences.isEmpty }

    var injectionBlock: String {
        guard !preferences.isEmpty else { return "" }
        var lines: [String] = []
        lines.append("── KNOWN USER PREFERENCES (apply these — derived from project history) ──")
        for pref in preferences.prefix(6) {
            lines.append("• \(pref.trait)  [\(pref.confidence.rawValue) confidence — score \(Int(pref.score))]")
        }
        if let top = preferences.first, !top.evidenceItems.isEmpty {
            lines.append("")
            lines.append("Top evidence:")
            for item in top.evidenceItems.prefix(3) {
                lines.append("  – \(item)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Trait Signal

private struct TraitSignal {
    let name: String
    let keywords: [String]
}

// MARK: - PreferenceEngine
//
// Pure compute function — journal in, profile out.
// Never stores state. Call compute(jobs:entries:) from any context using value-type snapshots.

enum PreferenceEngine {

    private static let traits: [TraitSignal] = [
        TraitSignal(name: "Apple-inspired typography",
                    keywords: ["apple typography", "sf pro", "san francisco font", "apple font", "-apple-system"]),
        TraitSignal(name: "Dark backgrounds",
                    keywords: ["dark background", "dark mode", "dark theme", "dark bg", "navy background",
                               "black background", "dark color scheme"]),
        TraitSignal(name: "Light / bright backgrounds",
                    keywords: ["light background", "white background", "light mode", "bright background", "clean white"]),
        TraitSignal(name: "High-contrast CTAs",
                    keywords: ["high contrast", "bold cta", "contrast cta", "strong button", "cta contrast", "button contrast"]),
        TraitSignal(name: "Testimonials",
                    keywords: ["testimonial", "reviews section", "social proof", "client quotes",
                               "customer reviews", "testimonials"]),
        TraitSignal(name: "Minimal layout",
                    keywords: ["minimal", "minimalist", "clean layout", "simple layout", "whitespace",
                               "lots of space", "breathing room"]),
        TraitSignal(name: "Glassmorphism",
                    keywords: ["glassmorphism", "glass effect", "frosted glass", "backdrop-blur", "glass card"]),
        TraitSignal(name: "Bold hero section",
                    keywords: ["bold hero", "large hero", "full-screen hero", "full bleed", "big headline",
                               "oversized type"]),
        TraitSignal(name: "Scroll animations",
                    keywords: ["scroll animation", "scroll effect", "fade in on scroll", "parallax",
                               "intersection observer", "animate on scroll"]),
        TraitSignal(name: "Gradient backgrounds",
                    keywords: ["gradient background", "mesh gradient", "aurora gradient", "gradient color",
                               "linear-gradient", "radial-gradient"]),
        TraitSignal(name: "Short / concise copy",
                    keywords: ["shorter copy", "less text", "fewer words", "concise copy", "brief copy",
                               "reduce text"]),
        TraitSignal(name: "Card-based layout",
                    keywords: ["card layout", "card grid", "feature cards", "card design", "cards section"]),
        TraitSignal(name: "Serif typography",
                    keywords: ["serif font", "playfair", "garamond", "georgia font", "bodoni",
                               "editorial font", "times new roman"]),
        TraitSignal(name: "Video background",
                    keywords: ["video background", "background video", "video hero", "video bg"]),
        TraitSignal(name: "Client logos / trust badges",
                    keywords: ["client logos", "partner logos", "trust badges", "logo strip",
                               "as seen in", "featured in"]),
        TraitSignal(name: "Sticky navigation",
                    keywords: ["sticky nav", "sticky header", "floating nav", "fixed header"]),
    ]

    static func compute(jobs: [AgentJob], entries: [OutputEntry]) -> PreferenceProfile {
        var scores: [String: Double] = [:]
        var evidence: [String: [String]] = [:]

        let jobIndex = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        let websiteEntries = entries.filter { $0.type == .website }

        for entry in websiteEntries {

            // ── CriticLens ──────────────────────────────────────────────────────
            // High critic scores on jobs whose prompts mention a trait = quality confirmation
            for version in entry.versions {
                guard let sourceId = version.sourceJobId,
                      let job = jobIndex[sourceId],
                      let criticJSON = job.result?.metadata["criticReport"],
                      let criticData = criticJSON.data(using: .utf8),
                      let report = try? JSONDecoder().decode(CriticReport.self, from: criticData),
                      report.overallScore >= 7
                else { continue }

                let searchText = job.prompt.lowercased()
                for signal in traits where found(signal.keywords, in: searchText) {
                    let boost = Double(report.overallScore - 6) * 2.0  // 7→+2, 8→+4, 9→+6, 10→+8
                    scores[signal.name, default: 0] += boost
                    addEvidence(to: &evidence, trait: signal.name,
                                item: "Critic scored \(report.overallScore)/10 on '\(String(entry.name.prefix(30)))'")
                }
            }

            // ── VersionLens ─────────────────────────────────────────────────────
            // Traits present in edit prompts across many versions = retained preference
            if entry.versions.count >= 3 {
                let allVersionText = entry.versions.compactMap { $0.editPrompt?.lowercased() }.joined(separator: " ")
                for signal in traits where found(signal.keywords, in: allVersionText) {
                    let boost = min(Double(entry.versions.count) * 2.5, 10.0)
                    scores[signal.name, default: 0] += boost
                    addEvidence(to: &evidence, trait: signal.name,
                                item: "Retained across \(entry.versions.count) versions in '\(String(entry.name.prefix(30)))'")
                }
            }

            // ── EditHistoryLens ─────────────────────────────────────────────────
            // Traits explicitly requested in user edit messages = +4 per unique entry
            var seenInEntry = Set<String>()
            for msg in entry.editHistory where msg.role == .user {
                let lower = msg.content.lowercased()
                for signal in traits where found(signal.keywords, in: lower) && !seenInEntry.contains(signal.name) {
                    seenInEntry.insert(signal.name)
                    scores[signal.name, default: 0] += 4
                    addEvidence(to: &evidence, trait: signal.name,
                                item: "Requested: \"\(String(msg.content.prefix(60)))\"")
                }
            }

            // ── RestoreLens ─────────────────────────────────────────────────────
            // Restore events = strong preference for the original design direction
            let restoreCount = entry.versions.filter { $0.createdByAgent == "Restore" }.count
            if restoreCount > 0 {
                let sourceText = (entry.metadata["sourcePrompt"] ?? "").lowercased()
                for signal in traits where found(signal.keywords, in: sourceText) {
                    scores[signal.name, default: 0] += Double(restoreCount) * 12.0
                    addEvidence(to: &evidence, trait: signal.name,
                                item: "Reverted \(restoreCount)× to original in '\(String(entry.name.prefix(30)))'")
                }
            }

            // ── PublishingLens ──────────────────────────────────────────────────
            // Published = kept and committed = strong preference confirmation
            if entry.publishedUrl != nil {
                let sourceText = (entry.metadata["sourcePrompt"] ?? "").lowercased()
                for signal in traits where found(signal.keywords, in: sourceText) {
                    scores[signal.name, default: 0] += 6
                    addEvidence(to: &evidence, trait: signal.name,
                                item: "Published '\(String(entry.name.prefix(30)))'")
                }
            }

            // ── FavoriteLens ────────────────────────────────────────────────────
            if entry.favorite {
                let sourceText = (entry.metadata["sourcePrompt"] ?? "").lowercased()
                for signal in traits where found(signal.keywords, in: sourceText) {
                    scores[signal.name, default: 0] += 4
                    addEvidence(to: &evidence, trait: signal.name,
                                item: "Marked favorite: '\(String(entry.name.prefix(30)))'")
                }
            }
        }

        let preferences = scores
            .compactMap { trait, score -> Preference? in
                let tier = confidenceTier(for: score)
                guard tier != .low else { return nil }
                return Preference(
                    trait: trait,
                    score: score,
                    confidence: tier,
                    evidenceItems: evidence[trait] ?? []
                )
            }
            .sorted { $0.score > $1.score }

        return PreferenceProfile(
            preferences: preferences,
            computedAt: Date(),
            dataPointsAnalyzed: websiteEntries.count
        )
    }

    // MARK: - Helpers

    private static func found(_ keywords: [String], in text: String) -> Bool {
        keywords.contains { text.contains($0) }
    }

    private static func addEvidence(to evidence: inout [String: [String]], trait: String, item: String) {
        var items = evidence[trait] ?? []
        guard !items.contains(item), items.count < 5 else { return }
        items.append(item)
        evidence[trait] = items
    }

    private static func confidenceTier(for score: Double) -> ConfidenceTier {
        if score > 20 { return .high }
        if score >= 8  { return .medium }
        return .low
    }
}
