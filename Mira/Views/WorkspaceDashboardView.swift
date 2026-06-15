import SwiftUI

// MARK: - Workspace Dashboard
//
// Computed fresh on each appearance from AgentJobStore + OutputStore + PreferenceEngine.
// No stored state — always reflects current journal truth.

struct WorkspaceDashboardView: View {
    @ObservedObject private var outputStore = OutputStore.shared
    @ObservedObject private var jobStore    = AgentJobStore.shared
    @ObservedObject private var reviewStore = ReviewStore.shared

    @State private var dashData: DashboardData = .empty
    @State private var insights: [CorrelationInsight] = []
    @State private var recommendations: [PolicyRecommendation] = []
    @State private var causalInsights: [CausalInsight] = []
    @State private var generatingReview = false

    private let accent = DS.Colors.accent

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                statsRow
                if !recommendations.isEmpty { recommendedActionsSection }
                attentionPanel
                if !dashData.topPreferences.isEmpty { preferenceSection }
                scoreSection
                if !insights.isEmpty { insightsSection }
                causalInsightsSection
                if !dashData.topEntries.isEmpty { topPerformersSection }
                reviewSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .onAppear { compute() }
        .onChange(of: outputStore.entries.count) { compute() }
        .onChange(of: jobStore.jobs.count) { compute() }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 6) {
            statChip(value: "\(dashData.thisMonthCreated)",    label: "Created",   icon: "plus.circle.fill",    color: accent)
            statChip(value: "\(dashData.thisMonthPublished)",  label: "Published", icon: "paperplane.fill",     color: Color(red: 0.3, green: 0.85, blue: 0.55))
            statChip(value: "\(dashData.thisMonthVersions)",   label: "Versions",  icon: "clock.arrow.circlepath", color: Color(red: 0.9, green: 0.65, blue: 0.2))
            statChip(value: "\(dashData.totalWebsites)",       label: "All Time",  icon: "globe",               color: Color(red: 0.65, green: 0.45, blue: 0.9))
        }
    }

    private func statChip(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color.opacity(0.8))
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    // MARK: - Preferences

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Your Design Profile", icon: "person.crop.circle.badge.checkmark")
            VStack(spacing: 4) {
                ForEach(dashData.topPreferences.prefix(4), id: \.trait) { pref in
                    preferenceRow(pref)
                }
            }
        }
    }

    private func preferenceRow(_ pref: Preference) -> some View {
        HStack(spacing: 8) {
            Text(pref.trait)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    let barW = min(geo.size.width * CGFloat(pref.score / 40.0), geo.size.width)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(confidenceColor(pref.confidence))
                        .frame(width: barW)
                }
            }
            .frame(width: 80, height: 4)
            Text(pref.confidence.rawValue)
                .font(.system(size: 9))
                .foregroundColor(confidenceColor(pref.confidence).opacity(0.8))
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func confidenceColor(_ tier: ConfidenceTier) -> Color {
        switch tier {
        case .high:   return Color(red: 0.3, green: 0.85, blue: 0.55)
        case .medium: return Color(red: 0.9, green: 0.65, blue: 0.2)
        case .low:    return Color.white.opacity(0.25)
        }
    }

    // MARK: - Scores

    private var scoreSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Quality Scores", icon: "chart.bar.fill")
            if dashData.hasScores {
                HStack(spacing: 6) {
                    scoreCard(value: dashData.avgVisual,       label: "Visual",     color: accent)
                    scoreCard(value: dashData.avgConversion,   label: "Conversion", color: Color(red: 0.9, green: 0.65, blue: 0.2))
                    scoreCard(value: dashData.avgMobile,       label: "Mobile",     color: Color(red: 0.3, green: 0.85, blue: 0.55))
                    scoreCard(value: dashData.avgAccessibility, label: "Access.",   color: Color(red: 0.65, green: 0.45, blue: 0.9))
                }
            } else {
                Text("Build with Pro or Multi-Agent mode to generate quality scores.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.vertical, 4)
            }
        }
    }

    private func scoreCard(value: Double?, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            if let v = value {
                Text(String(format: "%.1f", v))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(scoreTextColor(v))
            } else {
                Text("—")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.22))
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(value.map { scoreTextColor($0) }?.opacity(0.08) ?? Color.white.opacity(0.04))
        )
    }

    private func scoreTextColor(_ v: Double) -> Color {
        if v >= 8 { return Color(red: 0.3, green: 0.85, blue: 0.55) }
        if v >= 6 { return Color(red: 0.9, green: 0.65, blue: 0.2) }
        return Color(red: 1.0, green: 0.42, blue: 0.42)
    }

    // MARK: - Top Performers

    private var topPerformersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Top Performers", icon: "trophy.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dashData.topEntries, id: \.id) { card in
                        topPerformerCard(card)
                    }
                }
            }
        }
    }

    private func topPerformerCard(_ card: EntryCard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(card.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                if card.published {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.55).opacity(0.7))
                }
            }
            if let score = card.overallScore {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundColor(Color(red: 0.9, green: 0.75, blue: 0.2))
                    Text(String(format: "%.1f", score))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                }
            }
            Text("\(card.versionCount) version\(card.versionCount == 1 ? "" : "s")")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.28))
        }
        .padding(10)
        .frame(width: 130)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    // MARK: - Review Snippet

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Workspace Review", icon: "doc.text.magnifyingglass")
                Spacer()
                if let r = reviewStore.latest {
                    Text(r.relativeTime)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
            if let review = reviewStore.latest {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(review.recommendations.prefix(2), id: \.self) { rec in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 9))
                                .foregroundColor(accent.opacity(0.7))
                                .padding(.top, 1)
                            Text(rec)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                Button(action: {
                    guard !generatingReview else { return }
                    generatingReview = true
                    Task {
                        await BackgroundScheduler.shared.generateWorkspaceReview()
                        generatingReview = false
                    }
                }) {
                    HStack(spacing: 6) {
                        if generatingReview {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10))
                                .foregroundColor(accent.opacity(0.7))
                        }
                        Text(generatingReview ? "Generating review…" : "Generate workspace review →")
                            .font(.system(size: 11))
                            .foregroundColor(generatingReview ? .white.opacity(0.35) : accent.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Recommended Actions

    private var recommendedActionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Recommended Actions", icon: "bolt.badge.checkmark.fill")
            VStack(spacing: 5) {
                ForEach(recommendations.prefix(3)) { rec in
                    recommendationRow(rec)
                }
            }
        }
    }

    private func recommendationRow(_ rec: PolicyRecommendation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: rec.categoryIcon)
                .font(.system(size: 11))
                .foregroundColor(accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.category)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text(rec.rationale)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.40))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(String(format: "%.1f", rec.expectedImpact))")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.3, green: 0.85, blue: 0.55))
                Text(rec.confidence.rawValue)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.28))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Attention Panel

    @ViewBuilder
    private var attentionPanel: some View {
        let urgent = AttentionEngine.shared.directives.filter { $0.urgency > 0.6 }
        if !urgent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Focus Now", icon: "eye.fill")
                ForEach(urgent.prefix(2)) { directive in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(red: 0.9, green: 0.65, blue: 0.2))
                            .frame(width: 6, height: 6)
                        Text(directive.reason)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.72))
                    }
                }
            }
        }
    }

    // MARK: - Causal Insights

    @ViewBuilder
    private var causalInsightsSection: some View {
        let meaningful = causalInsights.filter(\.isStatisticallyMeaningful)
        if !meaningful.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Causal Effects", icon: "arrow.triangle.branch")
                VStack(spacing: 4) {
                    ForEach(meaningful.prefix(3)) { insight in
                        causalRow(insight)
                    }
                }
            }
        }
    }

    private func causalRow(_ insight: CausalInsight) -> some View {
        HStack(spacing: 8) {
            Image(systemName: insight.categoryIcon)
                .font(.system(size: 10))
                .foregroundColor(Color(red: 0.65, green: 0.45, blue: 0.9).opacity(0.8))
                .frame(width: 14)
            Text(insight.category)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(insight.formattedCausalEffect)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(insight.causalEffect >= 0
                    ? Color(red: 0.3, green: 0.85, blue: 0.55)
                    : Color(red: 1.0, green: 0.42, blue: 0.42))
            Text("n=\(insight.treatedCount)/\(insight.controlCount)")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.22))
        }
    }

    // MARK: - Shared header

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.35))
    }

    // MARK: - Insights

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("What Works", icon: "chart.line.uptrend.xyaxis")
            VStack(spacing: 4) {
                // Flat (aggregate) insights first
                ForEach(insights.filter { !$0.isConditioned }.prefix(3)) { insight in
                    insightRow(insight)
                }
                // Conditioned insights — indented to signal they're sub-findings
                let conditioned = insights.filter(\.isConditioned).prefix(2)
                if !conditioned.isEmpty {
                    ForEach(Array(conditioned)) { insight in
                        insightRow(insight)
                            .padding(.leading, 14)
                    }
                }
            }
        }
    }

    private func insightRow(_ insight: CorrelationInsight) -> some View {
        HStack(spacing: 7) {
            // Confidence indicator
            Image(systemName: insight.confidence.icon)
                .font(.system(size: 8))
                .foregroundColor(confidenceColor(insight.confidence))
                .frame(width: 10)

            Image(systemName: insight.categoryIcon)
                .font(.system(size: 10))
                .foregroundColor(accent.opacity(0.60))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(insight.category)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.72))
                if let tier = insight.baselineTier {
                    Text(tier.range + " baseline")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.30))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(insight.formattedImpact)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(insight.avgOverallDelta >= 0
                    ? Color(red: 0.3, green: 0.85, blue: 0.55)
                    : Color(red: 1.0, green: 0.42, blue: 0.42))

            Text(insight.contextLabel)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.25))
                .frame(width: 76, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: insight))
    }

    private func confidenceColor(_ c: InsightConfidence) -> Color {
        switch c {
        case .high:   return Color(red: 0.3, green: 0.85, blue: 0.55)
        case .medium: return Color(red: 0.9, green: 0.65, blue: 0.2)
        case .low:    return Color.white.opacity(0.20)
        }
    }

    private func accessibilityLabel(for insight: CorrelationInsight) -> String {
        var parts = ["\(insight.category): \(insight.formattedImpact)"]
        if let tier = insight.baselineTier { parts.append("at \(tier.range) baseline") }
        parts.append("\(insight.contextLabel), \(insight.confidence.rawValue) confidence")
        return parts.joined(separator: ", ")
    }

    // MARK: - Compute

    private func compute() {
        let jobs    = jobStore.jobs
        let entries = outputStore.entries
        dashData = DashboardData.compute(jobs: jobs, entries: entries)
        insights = CorrelationEngine.compute(from: jobs)
        recommendations = PolicyEngine.shared.recommendGeneral(jobs: jobs)
        causalInsights = CausalEngine.compute(from: jobs, tracker: ControlGroupTracker.shared)
        AttentionEngine.shared.update(from: recommendations)
    }
}

// MARK: - Dashboard Data (pure compute)

struct EntryCard {
    let id: UUID
    let name: String
    let versionCount: Int
    let overallScore: Double?
    let published: Bool
}

struct DashboardData {
    let thisMonthCreated: Int
    let thisMonthPublished: Int
    let thisMonthVersions: Int
    let totalWebsites: Int
    let avgVisual: Double?
    let avgConversion: Double?
    let avgMobile: Double?
    let avgAccessibility: Double?
    let topPreferences: [Preference]
    let topEntries: [EntryCard]

    var hasScores: Bool {
        avgVisual != nil || avgConversion != nil
    }

    static let empty = DashboardData(
        thisMonthCreated: 0, thisMonthPublished: 0, thisMonthVersions: 0,
        totalWebsites: 0, avgVisual: nil, avgConversion: nil,
        avgMobile: nil, avgAccessibility: nil,
        topPreferences: [], topEntries: []
    )

    static func compute(jobs: [AgentJob], entries: [OutputEntry]) -> DashboardData {
        let websiteEntries = entries.filter { $0.type == .website }
        let monthStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()

        let thisMonth     = websiteEntries.filter { $0.createdAt >= monthStart }
        let created       = thisMonth.count
        let published     = thisMonth.filter { $0.publishedUrl != nil }.count
        let versionCount  = thisMonth.reduce(0) { $0 + $1.versions.count }
        let total         = websiteEntries.count

        // Critic scores
        let jobIndex = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        var vScores: [Double] = [], cScores: [Double] = [], mScores: [Double] = [], aScores: [Double] = []
        var entryScores: [(entry: OutputEntry, score: Double)] = []

        for entry in websiteEntries {
            var entryScoreSum = 0.0
            var entryScoreCount = 0
            for version in entry.versions {
                guard let sourceId = version.sourceJobId,
                      let job = jobIndex[sourceId],
                      let json = job.result?.metadata["criticReport"],
                      let data = json.data(using: .utf8),
                      let report = try? JSONDecoder().decode(CriticReport.self, from: data)
                else { continue }
                vScores.append(Double(report.visualQuality))
                cScores.append(Double(report.conversionPotential))
                mScores.append(Double(report.mobileExperience))
                aScores.append(Double(report.accessibility))
                entryScoreSum += Double(report.overallScore)
                entryScoreCount += 1
            }
            if entryScoreCount > 0 {
                entryScores.append((entry: entry, score: entryScoreSum / Double(entryScoreCount)))
            }
        }

        func avg(_ arr: [Double]) -> Double? {
            arr.isEmpty ? nil : arr.reduce(0, +) / Double(arr.count)
        }

        // Top performers
        let topEntries = entryScores
            .sorted { $0.score > $1.score }
            .prefix(4)
            .map { pair in
                EntryCard(
                    id: pair.entry.id,
                    name: pair.entry.name,
                    versionCount: pair.entry.versions.count,
                    overallScore: pair.score,
                    published: pair.entry.publishedUrl != nil
                )
            }

        // Preferences
        let profile = PreferenceEngine.compute(jobs: jobs, entries: entries)

        return DashboardData(
            thisMonthCreated: created,
            thisMonthPublished: published,
            thisMonthVersions: versionCount,
            totalWebsites: total,
            avgVisual: avg(vScores),
            avgConversion: avg(cScores),
            avgMobile: avg(mScores),
            avgAccessibility: avg(aScores),
            topPreferences: profile.preferences,
            topEntries: Array(topEntries)
        )
    }
}
