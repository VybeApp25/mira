import SwiftUI

// MARK: - Reliability Dashboard
//
// Reads live from TelemetryService, ErrorService, and AgentJobStore.
// Re-derives on every body evaluation — no stale state.

struct ReliabilityDashboardView: View {
    @ObservedObject private var jobStore  = AgentJobStore.shared
    @ObservedObject private var telemetry = TelemetryService.shared

    private let accent = DS.Colors.accent
    private let green  = Color(red: 0.30, green: 0.85, blue: 0.55)
    private let amber  = Color(red: 0.90, green: 0.65, blue: 0.20)
    private let red    = Color(red: 1.00, green: 0.42, blue: 0.42)

    private var data: ReliabilityData {
        ReliabilityData.compute(
            telemetry: telemetry,
            errors:    ErrorService.shared,
            jobs:      jobStore.jobs
        )
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                successRatesRow
                publishFunnelSection
                errorCategorySection
                agentActivitySection
                recoverySection
                improvementOutcomesSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Success Rates

    private var successRatesRow: some View {
        HStack(spacing: 6) {
            rateChip(rate: data.buildSuccessRate,        label: "Builds",    icon: "globe",                  tint: rateColor(data.buildSuccessRate))
            rateChip(rate: data.publishSuccessRate,      label: "Publish",   icon: "paperplane.fill",         tint: rateColor(data.publishSuccessRate))
            rateChip(rate: data.improvementAcceptRate,   label: "Improve",   icon: "star.leadinghalf.filled", tint: rateColor(data.improvementAcceptRate))
            rateChip(rate: data.recoverySuccessRate,     label: "Recovery",  icon: "arrow.clockwise",         tint: rateColor(data.recoverySuccessRate))
        }
    }

    private func rateChip(rate: Double?, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(tint.opacity(0.80))
            Group {
                if let r = rate {
                    Text("\(Int(r * 100))%")
                        .foregroundColor(tint)
                } else {
                    Text("—")
                        .foregroundColor(.white.opacity(0.22))
                }
            }
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
    }

    // MARK: - Publish Funnel

    private var publishFunnelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Publish Funnel", icon: "paperplane.fill")
            HStack(spacing: 0) {
                funnelStep(count: data.publishStarted,   label: "Started",  tint: accent)
                funnelArrow
                funnelStep(count: data.publishSucceeded, label: "Deployed", tint: green)
                funnelArrow
                funnelStep(count: data.publishFailed,    label: "Failed",   tint: data.publishFailed > 0 ? red : .white.opacity(0.20))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        }
    }

    private func funnelStep(count: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(count > 0 ? tint : .white.opacity(0.22))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.30))
        }
        .frame(maxWidth: .infinity)
    }

    private var funnelArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.18))
    }

    // MARK: - Error Categories

    private var errorCategorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Error Breakdown", icon: "exclamationmark.triangle.fill")
                Spacer()
                Text("\(data.totalErrors) total")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.25))
            }

            if data.totalErrors == 0 {
                Text("No errors recorded yet.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 5) {
                    ForEach(data.topCategories, id: \.category.rawValue) { item in
                        categoryBar(item)
                    }
                }
            }
        }
    }

    private func categoryBar(_ item: CategoryCount) -> some View {
        let fraction = data.totalErrors > 0
            ? CGFloat(item.count) / CGFloat(data.totalErrors)
            : 0
        let tint = categoryColor(item.category)

        return HStack(spacing: 8) {
            Text(item.category.displayName)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 88, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            Text("\(item.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 24, alignment: .trailing)
        }
    }

    // MARK: - Agent Activity

    private var agentActivitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Agent Activity", icon: "cpu")
            HStack(spacing: 6) {
                activityChip(value: "\(data.totalBuildsCompleted)", label: "Builds",    icon: "globe",                 tint: accent)
                activityChip(value: "\(data.totalImprovements)",    label: "Improved",  icon: "wand.and.sparkles",     tint: amber)
                activityChip(
                    value: data.avgBuildSeconds > 0
                        ? (data.avgBuildSeconds >= 60
                            ? String(format: "%.0fm", data.avgBuildSeconds / 60)
                            : String(format: "%.0fs", data.avgBuildSeconds))
                        : "—",
                    label: "Avg Build",
                    icon: "clock",
                    tint: .white.opacity(0.40)
                )
            }
        }
    }

    private func activityChip(value: String, label: String, icon: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(tint.opacity(0.75))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Recovery", icon: "arrow.clockwise.circle.fill")
            if data.recoveryAttempts == 0 {
                Text("No recovery attempts yet.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 6) {
                    activityChip(value: "\(data.recoveryAttempts)",  label: "Attempted",  icon: "arrow.clockwise",         tint: accent)
                    activityChip(value: "\(data.recoverySuccesses)", label: "Succeeded",  icon: "checkmark.circle.fill",   tint: green)
                    if let topAction = data.topRecoveryAction {
                        activityChip(value: topAction.replacingOccurrences(of: "_", with: " ").capitalized,
                                     label: "Top Action",
                                     icon: "bolt.circle.fill",
                                     tint: amber)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Improvement Outcomes

    private var improvementOutcomesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Improvement Outcomes", icon: "wand.and.sparkles")
                Spacer()
                let outcomes = data.outcomes
                if outcomes.count > 0 {
                    Text("\(outcomes.count) measured")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
            }

            let outcomes = data.outcomes
            if outcomes.count == 0 {
                Text("Run an improvement on a website to see score deltas.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.vertical, 4)
            } else {
                let summary = ImprovementOutcomeSummary.compute(from: jobStore.jobs)
                VStack(spacing: 5) {
                    deltaRow(label: "Visual",       delta: summary.avgVisual)
                    deltaRow(label: "Conversion",   delta: summary.avgConversion)
                    deltaRow(label: "Mobile",       delta: summary.avgMobile)
                    deltaRow(label: "Accessibility", delta: summary.avgAccessibility)
                    deltaRow(label: "Brand",        delta: summary.avgBrand)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
            }
        }
        .padding(.bottom, 6)
    }

    private func deltaRow(label: String, delta: Double) -> some View {
        let tint = delta > 0 ? green : (delta < 0 ? red : Color.white.opacity(0.30))
        let prefix = delta > 0 ? "+" : ""

        return HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 88, alignment: .leading)
            Spacer()
            Text("\(prefix)\(String(format: "%.1f", delta))")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.35))
    }

    private func rateColor(_ rate: Double?) -> Color {
        guard let r = rate else { return .white.opacity(0.25) }
        if r >= 0.85 { return green }
        if r >= 0.60 { return amber }
        return red
    }

    private func categoryColor(_ category: MiraErrorCategory) -> Color {
        switch category {
        case .integration, .authentication, .authorization: return amber
        case .network, .timeout:                            return accent
        case .rateLimit, .aiProvider:                       return Color(red: 0.65, green: 0.45, blue: 0.90)
        case .agentService:                                 return red
        default:                                            return Color.white.opacity(0.30)
        }
    }
}

// MARK: - Data model

struct CategoryCount {
    let category: MiraErrorCategory
    let count: Int
}

struct ReliabilityData {
    let buildSuccessRate: Double?
    let publishSuccessRate: Double?
    let improvementAcceptRate: Double?
    let recoverySuccessRate: Double?

    let publishStarted: Int
    let publishSucceeded: Int
    let publishFailed: Int

    let totalErrors: Int
    let topCategories: [CategoryCount]

    let totalBuildsCompleted: Int
    let totalImprovements: Int
    let avgBuildSeconds: Double

    let recoveryAttempts: Int
    let recoverySuccesses: Int
    let topRecoveryAction: String?

    let outcomes: [ImprovementOutcome]

    static let empty = ReliabilityData(
        buildSuccessRate: nil, publishSuccessRate: nil,
        improvementAcceptRate: nil, recoverySuccessRate: nil,
        publishStarted: 0, publishSucceeded: 0, publishFailed: 0,
        totalErrors: 0, topCategories: [],
        totalBuildsCompleted: 0, totalImprovements: 0, avgBuildSeconds: 0,
        recoveryAttempts: 0, recoverySuccesses: 0, topRecoveryAction: nil,
        outcomes: []
    )

    @MainActor
    static func compute(
        telemetry: TelemetryService,
        errors: ErrorService,
        jobs: [AgentJob]
    ) -> ReliabilityData {
        // Build success rate — only meaningful if at least one started
        let buildStartedCount = telemetry.count("agent_started")
        let buildSuccessRate: Double? = buildStartedCount > 0
            ? telemetry.websiteBuildSuccessRate : nil

        // Publish success rate
        let pStarted   = telemetry.count("publish_started")
        let pSucceeded = telemetry.count("publish_succeeded")
        let pFailed    = telemetry.count("publish_failed")
        let publishSuccessRate: Double? = pStarted > 0
            ? Double(pSucceeded) / Double(pStarted) : nil

        // Improvement acceptance rate
        let improveStarted = telemetry.count("improvement_requested")
        let improvementRate: Double? = improveStarted > 0
            ? telemetry.improvementAcceptanceRate : nil

        // Error breakdown
        let allErrors   = errors.records
        let totalErrors = allErrors.count
        let topCats = Dictionary(grouping: allErrors, by: \.category)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { CategoryCount(category: $0.key, count: $0.value) }

        // Agent activity
        let buildsCompleted = jobs.filter {
            $0.type == .websiteBuilder && $0.status == .completed
        }.count
        let improvements = jobs.filter {
            $0.type == .websiteImprovement && $0.status == .completed
        }.count

        // Recovery
        let attempted       = allErrors.compactMap(\.recoveryAttempt)
        let attemptCount    = attempted.count
        let successCount    = attempted.filter { $0.succeeded == true }.count
        let recoveryRate: Double? = attemptCount > 0
            ? Double(successCount) / Double(attemptCount) : nil
        let topAction = Dictionary(grouping: attempted, by: \.action)
            .mapValues(\.count)
            .max(by: { $0.value < $1.value })?.key

        let outcomes = jobs.compactMap { ImprovementOutcome(job: $0) }

        return ReliabilityData(
            buildSuccessRate:      buildSuccessRate,
            publishSuccessRate:    publishSuccessRate,
            improvementAcceptRate: improvementRate,
            recoverySuccessRate:   recoveryRate,
            publishStarted:        pStarted,
            publishSucceeded:      pSucceeded,
            publishFailed:         pFailed,
            totalErrors:           totalErrors,
            topCategories:         Array(topCats),
            totalBuildsCompleted:  buildsCompleted,
            totalImprovements:     improvements,
            avgBuildSeconds:       telemetry.averageBuildDurationSeconds,
            recoveryAttempts:      attemptCount,
            recoverySuccesses:     successCount,
            topRecoveryAction:     topAction,
            outcomes:              outcomes
        )
    }
}
