import Foundation

// MARK: - Workspace Review Agent
//
// Pure compute function: aggregates local journal data + calls Claude for synthesis.
// Call run(jobs:entries:apiKey:) with value-type snapshots from the main actor.

enum WorkspaceReviewAgent {

    static func run(jobs: [AgentJob], entries: [OutputEntry], apiKey: String) async -> WorkspaceReview? {
        let periodDays = 30
        let cutoff = Date().addingTimeInterval(-TimeInterval(periodDays * 86400))
        let claude = ClaudeService(apiKey: apiKey)

        // ── Compute activity stats ──────────────────────────────────────────────
        let recentEntries = entries.filter { $0.type == .website && $0.createdAt >= cutoff }
        let websitesCreated = recentEntries.count
        let websitesPublished = recentEntries.filter { $0.publishedUrl != nil }.count
        let totalVersions = recentEntries.reduce(0) { $0 + $1.versions.count }
        let restoreEvents = recentEntries.reduce(0) { count, e in
            count + e.versions.filter { $0.createdByAgent == "Restore" }.count
        }

        let recentJobs = jobs.filter { $0.type == .websiteImprovement && ($0.completedAt ?? Date()) >= cutoff }
        let improvementsRun = recentJobs.count

        // ── Critic score averages ───────────────────────────────────────────────
        var visualScores: [Double] = []
        var conversionScores: [Double] = []
        var mobileScores: [Double] = []
        var accessibilityScores: [Double] = []

        let jobIndex = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        for entry in recentEntries {
            for version in entry.versions {
                guard let sourceId = version.sourceJobId,
                      let job = jobIndex[sourceId],
                      let criticJSON = job.result?.metadata["criticReport"],
                      let data = criticJSON.data(using: .utf8),
                      let report = try? JSONDecoder().decode(CriticReport.self, from: data)
                else { continue }
                visualScores.append(Double(report.visualQuality))
                conversionScores.append(Double(report.conversionPotential))
                mobileScores.append(Double(report.mobileExperience))
                accessibilityScores.append(Double(report.accessibility))
            }
        }

        func avg(_ arr: [Double]) -> Double? {
            arr.isEmpty ? nil : arr.reduce(0, +) / Double(arr.count)
        }

        let avgVisual      = avg(visualScores)
        let avgConversion  = avg(conversionScores)
        let avgMobile      = avg(mobileScores)
        let avgAccessibility = avg(accessibilityScores)

        // ── Preference profile ──────────────────────────────────────────────────
        let profile = PreferenceEngine.compute(jobs: jobs, entries: entries)
        let topPatterns = profile.preferences.prefix(5).map { $0.trait }

        // ── Common edit request themes ──────────────────────────────────────────
        let editThemes = extractEditThemes(from: recentEntries)

        // ── Claude synthesis ────────────────────────────────────────────────────
        let statsBlock = buildStatsBlock(
            created: websitesCreated, published: websitesPublished,
            versions: totalVersions, improvements: improvementsRun,
            restores: restoreEvents,
            visual: avgVisual, conversion: avgConversion,
            mobile: avgMobile, accessibility: avgAccessibility
        )
        let patternBlock = topPatterns.isEmpty
            ? "No strong patterns yet."
            : topPatterns.map { "• \($0)" }.joined(separator: "\n")
        let editBlock = editThemes.isEmpty
            ? "No edit history yet."
            : editThemes.prefix(5).map { "• \($0)" }.joined(separator: "\n")

        let synthesisPrompt = """
        You are Mira's workspace intelligence system. Analyze this user's creative workspace data from the last \(periodDays) days and produce a concise review.

        ACTIVITY STATS
        \(statsBlock)

        TOP DESIGN PATTERNS (from preference engine)
        \(patternBlock)

        COMMON EDIT REQUESTS
        \(editBlock)

        Respond ONLY with valid JSON — no markdown, no explanation:
        {
          "insights": [
            "<specific insight about a creative pattern, data-driven, max 15 words>",
            "<second insight>",
            "<third insight>"
          ],
          "recommendations": [
            "<actionable recommendation based on score weakness or pattern, max 15 words>",
            "<second recommendation>"
          ],
          "suggestedProfile": [
            "<top trait>",
            "<second trait>",
            "<third trait>"
          ]
        }

        Be specific and data-driven. Reference actual numbers. No generic advice.
        """

        let raw = (try? await claude.ask(
            prompt: synthesisPrompt,
            system: "You are a creative workspace intelligence system. Output only valid JSON.",
            modelOverride: "claude-haiku-4-5-20251001",
            maxTokensOverride: 500
        )) ?? ""

        let (insights, recommendations, suggestedProfile) = parseSynthesis(raw, topPatterns: Array(topPatterns))

        return WorkspaceReview(
            id: UUID(),
            generatedAt: Date(),
            periodDays: periodDays,
            websitesCreated: websitesCreated,
            websitesPublished: websitesPublished,
            improvementsRun: improvementsRun,
            totalVersions: totalVersions,
            restoreEvents: restoreEvents,
            avgVisualQuality: avgVisual,
            avgConversionScore: avgConversion,
            avgMobileScore: avgMobile,
            avgAccessibilityScore: avgAccessibility,
            topPatterns: Array(topPatterns),
            insights: insights,
            recommendations: recommendations,
            suggestedProfile: suggestedProfile
        )
    }

    // MARK: - Helpers

    private static func extractEditThemes(from entries: [OutputEntry]) -> [String] {
        var freq: [String: Int] = [:]
        let themes: [(keywords: [String], label: String)] = [
            (["cta", "button", "call to action"], "CTA prominence"),
            (["contrast", "darker", "lighter"], "Color contrast"),
            (["whitespace", "spacing", "padding"], "Spacing/whitespace"),
            (["mobile", "responsive"], "Mobile layout"),
            (["testimonial", "review"], "Testimonials"),
            (["hero", "headline", "title"], "Hero section"),
            (["font", "typography", "text size"], "Typography"),
            (["animation", "motion"], "Animations"),
            (["color", "theme", "palette"], "Color theme"),
            (["section", "layout", "structure"], "Page structure"),
        ]
        for entry in entries {
            for msg in entry.editHistory where msg.role == .user {
                let lower = msg.content.lowercased()
                for theme in themes {
                    if theme.keywords.contains(where: { lower.contains($0) }) {
                        freq[theme.label, default: 0] += 1
                    }
                }
            }
        }
        return freq.sorted { $0.value > $1.value }.map { $0.key }
    }

    private static func buildStatsBlock(
        created: Int, published: Int, versions: Int, improvements: Int, restores: Int,
        visual: Double?, conversion: Double?, mobile: Double?, accessibility: Double?
    ) -> String {
        var lines = [
            "Websites created: \(created)",
            "Published: \(published)",
            "Total versions: \(versions)",
            "Improvement runs: \(improvements)",
            "Restore events: \(restores)",
        ]
        if let v = visual      { lines.append(String(format: "Avg visual quality: %.1f/10", v)) }
        if let c = conversion  { lines.append(String(format: "Avg conversion score: %.1f/10", c)) }
        if let m = mobile      { lines.append(String(format: "Avg mobile score: %.1f/10", m)) }
        if let a = accessibility { lines.append(String(format: "Avg accessibility: %.1f/10", a)) }
        return lines.joined(separator: "\n")
    }

    private static func parseSynthesis(
        _ raw: String,
        topPatterns: [String]
    ) -> (insights: [String], recommendations: [String], suggestedProfile: [String]) {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (
                insights: ["Building your design profile — run a few more builds to unlock insights."],
                recommendations: ["Try Multi-Agent mode for richer preference data."],
                suggestedProfile: topPatterns.isEmpty ? ["Dark", "Minimal", "High contrast"] : Array(topPatterns.prefix(3))
            )
        }

        let insights       = (obj["insights"]       as? [String]) ?? []
        let recommendations = (obj["recommendations"] as? [String]) ?? []
        let suggestedProfile = (obj["suggestedProfile"] as? [String])
            ?? (topPatterns.isEmpty ? ["Dark", "Minimal", "High contrast"] : Array(topPatterns.prefix(3)))

        return (insights: insights, recommendations: recommendations, suggestedProfile: suggestedProfile)
    }
}
