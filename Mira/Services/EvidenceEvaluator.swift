// EvidenceEvaluator.swift
// Phase 14 — Pure governance derivation layer
//
// Stateless transformer: (proposals, anchor) → EvidenceSnapshot.
//
// INVARIANT: BackgroundScheduler MUST NOT compute any governance signal directly.
// All governance must come from EvidenceEvaluator output. The scheduler is a
// trigger; this evaluator is the sole truth derivation layer.
//
// INVARIANT: Date() must never be called inside this file. The anchor parameter
// is the sole time reference. This enforces the Determinism invariant:
//   f(same proposals, same anchor) == identical EvidenceSnapshot, always,
//   regardless of wall-clock time, scheduler frequency, or UI state.
//
// Not wired to BackgroundScheduler yet. That wiring is a separate commit,
// added only after this evaluator is confirmed testable in isolation.

import Foundation

enum EvidenceEvaluator {

    // MARK: - Public interface

    /// Derives a complete EvidenceSnapshot from journal state alone.
    ///
    /// - Parameters:
    ///   - proposals: All ProposalMetadata across all projects. This is the full
    ///     journal record — pass every proposal the system has ever generated.
    ///   - anchor: The time reference for this snapshot. Must be injected by the
    ///     caller (BackgroundScheduler passes its fire time; tests pass a fixed date).
    ///     Never derived inside this function.
    static func evaluate(proposals: [ProposalMetadata], anchor: Date) -> EvidenceSnapshot {
        let dimensions                        = computeDimensions(from: proposals)
        let (trustworthiness, isPartial)      = computeTrustworthiness(from: proposals)

        return EvidenceSnapshot(
            id:                       UUID(),
            createdAt:                anchor,
            dimensions:               dimensions,
            trustworthiness:          trustworthiness,
            isPartialTrustworthiness: isPartial
        )
    }

    // MARK: - Dimensions

    private static func computeDimensions(from proposals: [ProposalMetadata]) -> EvidenceDimensions {
        let reviewed            = proposals.filter { $0.status == .approved || $0.status == .rejected }
        let totalReviewed       = reviewed.count
        let totalProposals      = proposals.count
        let projectsWithReviews = Set(reviewed.map(\.projectId)).count

        let volumeScore    = min(Double(totalReviewed) / 50.0, 1.0)
        let diversityScore = min(Double(projectsWithReviews) / 5.0, 1.0)
        let coverageScore  = totalProposals == 0
            ? 0.0
            : min(Double(totalReviewed) / Double(totalProposals), 1.0)
        let (stabilityScore, stabilityIsEstimated) = computeStability(from: reviewed)

        return EvidenceDimensions(
            volumeScore:          volumeScore,
            diversityScore:       diversityScore,
            coverageScore:        coverageScore,
            stabilityScore:       stabilityScore,
            stabilityIsEstimated: stabilityIsEstimated
        )
    }

    // Stability anchors entirely to proposal.reviewedAt dates — no wall-clock reference.
    private static func computeStability(from reviewed: [ProposalMetadata]) -> (Double, Bool) {
        guard reviewed.count >= 2 else { return (0.5, true) }

        var weekBuckets: [Date: (approved: Int, total: Int)] = [:]
        let cal = Calendar.current
        for p in reviewed {
            guard let d = p.reviewedAt else { continue }
            let weekStart = cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            weekBuckets[weekStart, default: (0, 0)].total   += 1
            if p.status == .approved {
                weekBuckets[weekStart, default: (0, 0)].approved += 1
            }
        }

        guard weekBuckets.count >= 2 else { return (0.5, true) }

        let rates  = weekBuckets.values.map { Double($0.approved) / Double($0.total) }
        let mean   = rates.reduce(0, +) / Double(rates.count)
        let stdDev = sqrt(rates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(rates.count))
        return (max(0, 1.0 - stdDev / 0.40), false)
    }

    // MARK: - Trustworthiness

    private static func computeTrustworthiness(from proposals: [ProposalMetadata]) -> (Double, Bool) {
        let reviewed = proposals.filter { $0.status == .approved || $0.status == .rejected }
        let approved = proposals.filter { $0.status == .approved }
        let total    = proposals.count

        guard !reviewed.isEmpty, total > 0 else { return (Double.nan, false) }

        let approvalRate = Double(approved.count) / Double(reviewed.count)
        let coverage     = Double(reviewed.count) / Double(total)

        let approvedWithConfidence = approved.filter { $0.reviewConfidence != nil }
        let weightedApproval: Double = {
            guard !approvedWithConfidence.isEmpty else { return Double.nan }
            let totalWeight = approvedWithConfidence.reduce(0.0) { $0 + ($1.reviewConfidence?.weight ?? 0) }
            let maxWeight   = Double(approvedWithConfidence.count) * ReviewConfidence.high.weight
            return totalWeight / maxWeight
        }()

        let calibScore = computeCalibrationScore(from: proposals)

        var product   = approvalRate * coverage
        var isPartial = false
        if !weightedApproval.isNaN { product *= weightedApproval } else { isPartial = true }
        if !calibScore.isNaN       { product *= calibScore       } else { isPartial = true }

        return (product, isPartial)
    }

    private static func computeCalibrationScore(from proposals: [ProposalMetadata]) -> Double {
        let reviewed = proposals.filter { $0.status == .approved || $0.status == .rejected }
        guard reviewed.count >= 5 else { return Double.nan }

        var groups: [Int: [ProposalMetadata]] = [:]
        for p in reviewed {
            let bucket = min(Int(p.confidence * 10), 9)
            groups[bucket, default: []].append(p)
        }

        let buckets: [(error: Double, count: Int)] = groups.keys.sorted().compactMap { idx in
            let items = groups[idx] ?? []
            guard !items.isEmpty else { return nil }
            let midpoint    = Double(idx) / 10.0 + 0.05
            let approvedN   = items.filter { $0.status == .approved }.count
            let approvalRate = Double(approvedN) / Double(items.count)
            return (abs(approvalRate - midpoint), items.count)
        }

        guard buckets.count >= 2 else { return Double.nan }

        let ece = buckets.reduce(0.0) { sum, b in
            sum + b.error * (Double(b.count) / Double(reviewed.count))
        }
        return max(0, 1.0 - ece)
    }
}
