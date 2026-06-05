// ProposalMetricsView.swift
// Phase 13B — Proposal quality dashboard
//
// Surfaces the confusion matrix + latency metrics accumulated by ProposalStore.
// This view exists to make the 13C promotion decision data-driven rather than
// architectural. Open from Settings → Proposal Metrics.

import SwiftUI

struct ProposalMetricsView: View {
    @ObservedObject private var engine        = ProjectEngine.shared
    @ObservedObject private var proposalStore = ProposalStore.shared

    private let accent   = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let successG = Color(red: 0.20, green: 0.84, blue: 0.60)
    private let amber    = Color(red: 1.0,  green: 0.75, blue: 0.20)
    private let muted    = Color.white.opacity(0.18)

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))
                if globalTotal == 0 {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            globalSection
                            Divider().background(Color.white.opacity(0.06))
                            gateBreakdownSection
                            Divider().background(Color.white.opacity(0.06))
                            latencySection
                            let allBuckets = globalCalibrationBuckets
                                if !allBuckets.isEmpty {
                                    Divider().background(Color.white.opacity(0.06))
                                    calibrationSection(buckets: allBuckets)
                                }
                                if !projectRows.isEmpty {
                                    Divider().background(Color.white.opacity(0.06))
                                    perProjectSection
                                }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .frame(width: 420, height: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Proposal Metrics")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            gateBadge
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// Shows whether the 13C promotion gate is currently satisfiable.
    private var gateBadge: some View {
        let (label, color) = gateStatus
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    // MARK: - Global confusion matrix

    private var globalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Outcomes · \(globalTotal) proposals total")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                matrixCell(value: globalApproved,  label: "Approved",    color: successG)
                matrixCell(value: globalRejected,  label: "Rejected",    color: Color(red: 1.0, green: 0.40, blue: 0.40))
                matrixCell(value: globalSuperseded, label: "Superseded", color: muted)
                matrixCell(value: globalStale,     label: "Unreviewed",  color: amber,
                           note: globalStale > 0 ? "> 7d" : nil)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func matrixCell(value: Int, label: String, color: Color, note: String? = nil) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(value == 0 ? .white.opacity(0.20) : color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.32))
            if let note = note {
                Text(note)
                    .font(.system(size: 8))
                    .foregroundColor(amber.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Gate breakdown

    private var gateBreakdownSection: some View {
        let (statusLabel, _) = gateStatus
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("13C gate · \(statusLabel)")
            VStack(spacing: 4) {
                gateRow("Proposals",      value: "\(globalTotal)",        threshold: "≥ 20",   passing: globalTotal >= 20)
                gateRow("Approval rate",  value: rateString(globalApprovalRate),   threshold: "≥ 75%",  passing: !globalApprovalRate.isNaN  && globalApprovalRate  >= 0.75)
                gateRow("Rejection rate", value: rateString(globalRejectionRate),  threshold: "≤ 15%",  passing: !globalRejectionRate.isNaN && globalRejectionRate <= 0.15)
                gateRow("Superseded",     value: rateString(globalSupersededRate), threshold: "≤ 20%",  passing: !globalSupersededRate.isNaN && globalSupersededRate <= 0.20)
                gateRow("Specificity",    value: specString(globalSpecificity),    threshold: "≥ 0.50", passing: !globalSpecificity.isNaN   && globalSpecificity   >= 0.50)
                if !globalWeightedApproval.isNaN {
                    confidenceSignalRow
                }
                if !globalTrustworthiness.0.isNaN {
                    trustworthinessRow
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var trustworthinessRow: some View {
        let (score, partial) = globalTrustworthiness
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 9))
                    .foregroundColor(accent.opacity(0.55))
                    .frame(width: 12)
                Text("Trustworthiness" + (partial ? " (partial)" : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.65))
                Spacer()
                Text(String(format: "%.0f%%", score * 100))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(trustColor(score))
                Text("composite")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.20))
                    .frame(width: 60, alignment: .trailing)
            }
            Text("approval × coverage" + (!globalWeightedApproval.isNaN ? " × reviewer confidence" : "") + (!globalCalibrationScore.isNaN ? " × calibration" : ""))
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.22))
                .padding(.leading, 20)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(accent.opacity(0.10), lineWidth: 0.5))
    }

    private func trustColor(_ score: Double) -> Color {
        if score >= 0.60 { return successG }
        if score >= 0.35 { return amber }
        return Color(red: 1.0, green: 0.40, blue: 0.40)
    }

    /// Informational row — no gate threshold yet. Distinguishes 80% high-confidence
    /// approval from 80% low-confidence approval. Threshold calibrated from field data.
    private var confidenceSignalRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.28))
                .frame(width: 12)
            Text("Weighted approval")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.50))
            Spacer()
            Text(rateString(globalWeightedApproval))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
            Text("signal")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.20))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func gateRow(_ label: String, value: String, threshold: String, passing: Bool) -> some View {
        let failColor = Color(red: 1.0, green: 0.40, blue: 0.40)
        return HStack(spacing: 8) {
            Image(systemName: passing ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(passing ? successG : failColor)
                .frame(width: 12)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(passing ? .white.opacity(0.82) : failColor.opacity(0.90))
            Text(threshold)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.22))
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(passing ? Color.white.opacity(0.03) : failColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func rateString(_ rate: Double) -> String {
        rate.isNaN ? "—" : String(format: "%.0f%%", rate * 100)
    }

    private func specString(_ score: Double) -> String {
        score.isNaN ? "—" : String(format: "%.2f", score)
    }

    // MARK: - Latency

    private var latencySection: some View {
        let latencies = aggregateLatencies()
        return VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Review latency")
            if latencies.isEmpty {
                Text("No reviewed proposals yet.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.28))
            } else {
                HStack(spacing: 8) {
                    latencyStat(label: "Average", value: formatLatency(average(latencies)))
                    latencyStat(label: "Median",  value: formatLatency(median(latencies)))
                    latencyStat(label: "Fastest", value: formatLatency(latencies.min() ?? 0))
                    latencyStat(label: "Slowest", value: formatLatency(latencies.max() ?? 0))
                }
            }
            if globalStale > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 10))
                        .foregroundColor(amber.opacity(0.75))
                    Text("\(globalStale) proposal\(globalStale == 1 ? "" : "s") pending > 7 days — unreviewed proposals suppress the approval signal.")
                        .font(.system(size: 10))
                        .foregroundColor(amber.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(amber.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func latencyStat(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.28))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Calibration

    private func calibrationSection(buckets: [CalibrationBucket]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionLabel("Calibration")
                Spacer()
                if !globalCalibrationScore.isNaN {
                    let score = globalCalibrationScore
                    Text(String(format: "ECE score %.2f", score))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(calibrationColor(score))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(calibrationColor(score).opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            // Column headers
            HStack(spacing: 0) {
                Text("Confidence").font(.system(size: 9)).foregroundColor(.white.opacity(0.22)).frame(width: 72, alignment: .leading)
                Text("N").font(.system(size: 9)).foregroundColor(.white.opacity(0.22)).frame(width: 28, alignment: .trailing)
                Text("Approved").font(.system(size: 9)).foregroundColor(.white.opacity(0.22)).frame(maxWidth: .infinity, alignment: .trailing)
                Text("Error").font(.system(size: 9)).foregroundColor(.white.opacity(0.22)).frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 10)

            VStack(spacing: 3) {
                ForEach(buckets) { bucket in
                    calibrationRow(bucket)
                }
            }

            if isMiscalibrated(buckets) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundColor(amber.opacity(0.75))
                    Text("Non-monotonic: a higher-confidence bucket has lower approval than a lower-confidence bucket.")
                        .font(.system(size: 10))
                        .foregroundColor(amber.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(amber.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func calibrationRow(_ bucket: CalibrationBucket) -> some View {
        let err = bucket.calibrationError
        let errColor: Color = abs(err) < 0.05 ? successG
                            : abs(err) < 0.15 ? amber
                            : Color(red: 1.0, green: 0.40, blue: 0.40)
        let errSign = err >= 0 ? "+" : ""

        return HStack(spacing: 0) {
            Text(bucket.rangeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.60))
                .frame(width: 72, alignment: .leading)
            Text("\(bucket.proposalCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 28, alignment: .trailing)
            Text(String(format: "%.0f%%", bucket.approvalRate * 100))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(String(format: "%@%.0f%%", errSign, err * 100))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(errColor)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func calibrationColor(_ score: Double) -> Color {
        if score >= 0.85 { return successG }
        if score >= 0.70 { return amber }
        return Color(red: 1.0, green: 0.40, blue: 0.40)
    }

    /// True when any bucket with higher confidence has lower approval than a bucket with lower confidence.
    private func isMiscalibrated(_ buckets: [CalibrationBucket]) -> Bool {
        let sorted = buckets.sorted { $0.lowerBound > $1.lowerBound }
        for i in 0..<(sorted.count - 1) {
            if sorted[i].approvalRate < sorted[i + 1].approvalRate { return true }
        }
        return false
    }

    // MARK: - Per-project rows

    private var perProjectSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("By project")
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
            ForEach(projectRows, id: \.id) { row in
                projectRow(row)
                Divider().background(Color.white.opacity(0.05)).padding(.leading, 18)
            }
        }
    }

    private func projectRow(_ row: ProjectRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    statChip("\(row.approved) approved", color: successG)
                    if row.rejected > 0  { statChip("\(row.rejected) rejected",   color: Color(red: 1.0, green: 0.40, blue: 0.40)) }
                    if row.superseded > 0 { statChip("\(row.superseded) superseded", color: muted) }
                    if row.pending > 0   { statChip("\(row.pending) pending",     color: amber) }
                }
            }
            Spacer()
            if !row.approvalRate.isNaN {
                VStack(spacing: 1) {
                    Text(String(format: "%.0f%%", row.approvalRate * 100))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(row.approvalRate >= 0.75 ? successG : amber)
                    Text("approval")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }

    private func statChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 9))
            .foregroundColor(color.opacity(0.75))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 28)).foregroundColor(.white.opacity(0.10))
            Text("No proposals yet")
                .font(.system(size: 12)).foregroundColor(.white.opacity(0.28))
            Text("Metrics appear once Phase 13B generates its first proposals.")
                .font(.system(size: 11)).foregroundColor(.white.opacity(0.18))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 13C gate status

    private var gateStatus: (String, Color) {
        if globalTotal == 0       { return ("Collecting",   muted) }
        if globalTotal < 20       { return ("Accumulating", amber) }
        let rate = globalApprovalRate
        if rate.isNaN             { return ("Accumulating", amber) }
        if rate >= 0.75
            && globalRejectionRate <= 0.15
            && globalSupersededRate <= 0.20
            && globalSpecificity >= 0.50 { return ("Gate met",   successG) }
        return ("Not yet",        amber)
    }

    // MARK: - Aggregate helpers

    private var projectRows: [ProjectRow] {
        engine.projects.compactMap { project in
            let m = proposalStore.metrics(for: project.id)
            guard m.total > 0 else { return nil }
            return ProjectRow(id: project.id, name: project.name,
                              approved: m.approved, rejected: m.rejected,
                              superseded: m.superseded, pending: m.pending,
                              approvalRate: m.approvalRate)
        }
        .sorted { $0.approved + $0.rejected > $1.approved + $1.rejected }
    }

    private var globalTotal:        Int    { projectRows.reduce(0) { $0 + $1.approved + $1.rejected + $1.superseded + $1.pending } }
    private var globalApproved:     Int    { projectRows.reduce(0) { $0 + $1.approved } }
    private var globalRejected:     Int    { projectRows.reduce(0) { $0 + $1.rejected } }
    private var globalSuperseded:   Int    { projectRows.reduce(0) { $0 + $1.superseded } }
    private var globalStale:        Int    { engine.projects.reduce(0) { $0 + proposalStore.metrics(for: $1.id).stalePendingCount } }

    private var globalReviewed:     Int    { globalApproved + globalRejected }
    private var globalApprovalRate: Double { globalReviewed == 0 ? Double.nan : Double(globalApproved) / Double(globalReviewed) }
    private var globalRejectionRate: Double { globalReviewed == 0 ? Double.nan : Double(globalRejected) / Double(globalReviewed) }
    private var globalSupersededRate: Double { globalTotal == 0 ? Double.nan : Double(globalSuperseded) / Double(globalTotal) }
    private var globalWeightedApproval: Double {
        let rates = engine.projects.map { proposalStore.metrics(for: $0.id).weightedApprovalRate }.filter { !$0.isNaN }
        return rates.isEmpty ? Double.nan : rates.reduce(0, +) / Double(rates.count)
    }

    /// Merge all per-project calibration buckets into a single global set by accumulating
    /// proposal counts per bucket index, then recomputing approval rates.
    private var globalCalibrationBuckets: [CalibrationBucket] {
        var counts:   [Int: Int] = [:]   // bucketIdx → total proposals
        var approvedN:[Int: Int] = [:]   // bucketIdx → approved proposals

        for project in engine.projects {
            for bucket in proposalStore.calibration(for: project.id) {
                let idx = Int(bucket.lowerBound * 10)
                let approvedCount = Int((bucket.approvalRate * Double(bucket.proposalCount)).rounded())
                counts[idx, default: 0]    += bucket.proposalCount
                approvedN[idx, default: 0] += approvedCount
            }
        }

        return counts.keys.sorted().reversed().compactMap { idx -> CalibrationBucket? in
            let total    = counts[idx] ?? 0
            guard total > 0 else { return nil }
            let approved = approvedN[idx] ?? 0
            let lowerBound  = Double(idx) / 10.0
            let approvalRate = Double(approved) / Double(total)
            return CalibrationBucket(
                lowerBound:           lowerBound,
                proposalCount:        total,
                approvalRate:         approvalRate,
                weightedApprovalRate: nil,
                calibrationError:     approvalRate - (lowerBound + 0.05)
            )
        }
    }

    private var globalCalibrationScore: Double {
        let scores = engine.projects
            .map { proposalStore.metrics(for: $0.id).calibrationScore }
            .filter { !$0.isNaN }
        return scores.isEmpty ? Double.nan : scores.reduce(0, +) / Double(scores.count)
    }

    /// Returns (score, isPartial). Aggregated as the product of per-project index means,
    /// weighted by reviewed proposal count so active projects dominate.
    private var globalTrustworthiness: (Double, Bool) {
        let entries = engine.projects.map { proposalStore.metrics(for: $0.id) }
            .filter { !$0.trustworthinessIndex.isNaN }
        guard !entries.isEmpty else { return (Double.nan, false) }
        let totalReviewed = entries.reduce(0) { $0 + $1.approved + $1.rejected }
        guard totalReviewed > 0 else { return (Double.nan, false) }
        let weighted = entries.reduce(0.0) { sum, m in
            let w = Double(m.approved + m.rejected) / Double(totalReviewed)
            return sum + m.trustworthinessIndex * w
        }
        let partial = entries.contains { $0.isPartialTrustworthiness }
        return (weighted, partial)
    }

    private var globalSpecificity: Double {
        let scores = engine.projects.map { ProjectEngine.shared.backgroundCheckpointSpecificity(for: $0) }.filter { !$0.isNaN }
        return scores.isEmpty ? Double.nan : scores.reduce(0, +) / Double(scores.count)
    }

    private func aggregateLatencies() -> [TimeInterval] {
        engine.projects.flatMap { project -> [TimeInterval] in
            let proposals = proposalStore.load(for: project.id)
            return proposals.compactMap { p in
                guard let r = p.reviewedAt else { return nil }
                return r.timeIntervalSince(p.createdAt)
            }
        }
    }

    // MARK: - Math helpers

    private func average(_ values: [TimeInterval]) -> TimeInterval {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted(); return s[s.count / 2]
    }

    private func formatLatency(_ t: TimeInterval) -> String {
        if t < 60        { return "<1m" }
        if t < 3_600     { return "\(Int(t / 60))m" }
        if t < 86_400    { return "\(Int(t / 3_600))h" }
        return "\(Int(t / 86_400))d"
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.25))
            .tracking(1)
    }

    // MARK: - Row model

    private struct ProjectRow {
        let id:           UUID
        let name:         String
        let approved:     Int
        let rejected:     Int
        let superseded:   Int
        let pending:      Int
        let approvalRate: Double
    }
}
