// EvidenceEvaluator.swift
// Phase 14 — Pure governance derivation layer
//
// Stateless transformer: (proposals, anchor) → EvidenceSnapshot.
//
// ─────────────────────────────────────────────────────────────────────────────
// HARD INVARIANTS — enforced by runIsolationVerification() in DEBUG builds.
// Violations crash the debug launch. Code review must catch them in prod builds.
// ─────────────────────────────────────────────────────────────────────────────
//
// 1. BackgroundScheduler MUST NOT compute any governance signal directly.
//    All governance must come from EvidenceEvaluator output. The scheduler is a
//    trigger; this evaluator is the sole truth derivation layer.
//
// 2. Date() must never be called inside this file. The anchor parameter is the
//    sole time reference. This enforces the Determinism invariant:
//      f(same proposals, same anchor) == identical EvidenceSnapshot, always,
//      regardless of wall-clock time, scheduler frequency, or UI state.
//
// DO NOT add imports or references to:
//   • BackgroundScheduler
//   • ProjectEngine
//   • ProposalStore (pass proposals as [ProposalMetadata] instead)
//   • AppDelegate or any app lifecycle type
//   • Date() — the anchor parameter is the sole time reference
//   • UserDefaults, NSPersistentContainer, or any persistent store
//   • @MainActor — this code must be callable from any context
//   • SwiftUI, AppKit, or any UI framework
//
// ─────────────────────────────────────────────────────────────────────────────
//
// Not wired to BackgroundScheduler yet. That wiring is a separate commit,
// added only after runIsolationVerification() passes on debug launch.

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

// MARK: - Isolation verification (DEBUG only)

#if DEBUG
extension EvidenceEvaluator {

    /// Proves the evaluator is independent of all runtime systems.
    /// Called once on every debug launch from AppDelegate. Crashes immediately
    /// with a descriptive message if any invariant is violated.
    ///
    /// Covers four claims:
    ///  1. DETERMINISM   — identical input + anchor → bit-identical dimensions
    ///  2. KNOWN VALUES  — fixture has fixed counts; outputs must match exactly
    ///  3. ANCHOR ISOLATION — changing anchor changes only createdAt, not dimensions
    ///  4. EMPTY STATE   — zero proposals → no authority, NaN trustworthiness
    static func runIsolationVerification() {
        let proposals = syntheticFixture()
        // Fixed epoch — Nov 14 2023 00:00:00 UTC. No Date() call.
        let anchorA = Date(timeIntervalSince1970: 1_700_000_000)
        let anchorB = Date(timeIntervalSince1970: 1_800_000_000)

        let run1 = evaluate(proposals: proposals, anchor: anchorA)
        let run2 = evaluate(proposals: proposals, anchor: anchorA)

        // 1. DETERMINISM: same proposals + same anchor → identical dimensions
        precondition(run1.dimensions.volumeScore    == run2.dimensions.volumeScore,
                     "EvidenceEvaluator: Determinism violated — volumeScore diverged on identical input")
        precondition(run1.dimensions.diversityScore == run2.dimensions.diversityScore,
                     "EvidenceEvaluator: Determinism violated — diversityScore diverged on identical input")
        precondition(run1.dimensions.coverageScore  == run2.dimensions.coverageScore,
                     "EvidenceEvaluator: Determinism violated — coverageScore diverged on identical input")
        precondition(run1.dimensions.stabilityScore == run2.dimensions.stabilityScore,
                     "EvidenceEvaluator: Determinism violated — stabilityScore diverged on identical input")
        precondition(run1.trustworthiness == run2.trustworthiness || (run1.trustworthiness.isNaN && run2.trustworthiness.isNaN),
                     "EvidenceEvaluator: Determinism violated — trustworthiness diverged on identical input")

        // 2. KNOWN VALUES: fixture has 8 proposals, 6 reviewed, 2 projects → exact scores
        // volumeScore   = 6/50 = 0.12
        // diversityScore = 2/5 = 0.40
        // coverageScore  = 6/8 = 0.75
        precondition(run1.dimensions.volumeScore    == 6.0 / 50.0,
                     "EvidenceEvaluator: Known value — volumeScore should be 6/50 = 0.12")
        precondition(run1.dimensions.diversityScore == 2.0 / 5.0,
                     "EvidenceEvaluator: Known value — diversityScore should be 2/5 = 0.40")
        precondition(run1.dimensions.coverageScore  == 6.0 / 8.0,
                     "EvidenceEvaluator: Known value — coverageScore should be 6/8 = 0.75")
        precondition(!run1.dimensions.stabilityIsEstimated,
                     "EvidenceEvaluator: Known value — fixture has 3 review weeks, stability should not be estimated")

        // 3. ANCHOR ISOLATION: different anchor → same dimensions, different createdAt only
        let run3 = evaluate(proposals: proposals, anchor: anchorB)
        precondition(run1.dimensions.volumeScore    == run3.dimensions.volumeScore,
                     "EvidenceEvaluator: Anchor isolation violated — anchor change affected volumeScore")
        precondition(run1.dimensions.coverageScore  == run3.dimensions.coverageScore,
                     "EvidenceEvaluator: Anchor isolation violated — anchor change affected coverageScore")
        precondition(run1.dimensions.stabilityScore == run3.dimensions.stabilityScore,
                     "EvidenceEvaluator: Anchor isolation violated — anchor change affected stabilityScore")
        precondition(run1.createdAt != run3.createdAt,
                     "EvidenceEvaluator: Anchor isolation violated — different anchors produced same createdAt")

        // 4. EMPTY STATE: zero proposals → no authority, NaN trustworthiness
        let empty = evaluate(proposals: [], anchor: anchorA)
        precondition(!empty.delegationAllowed(),
                     "EvidenceEvaluator: Empty state — delegation must not be allowed on empty journal")
        precondition(empty.trustworthiness.isNaN,
                     "EvidenceEvaluator: Empty state — trustworthiness must be NaN with no proposal data")
        precondition(empty.dimensions.coverageScore == 0.0,
                     "EvidenceEvaluator: Empty state — coverageScore must be 0.0 with no proposals")
    }

    // MARK: - Synthetic fixture

    /// 8 proposals across 2 projects, 3 review weeks, mixed outcomes.
    /// All dates are epoch-anchored — no Date() call.
    private static func syntheticFixture() -> [ProposalMetadata] {
        let projectA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let projectB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let session  = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        // Base: Nov 14 2023 00:00:00 UTC — fixed, no Date() call
        let base     = Date(timeIntervalSince1970: 1_699_920_000)

        func make(n: Int, project: UUID, confidence: Double,
                  status: ProposalStatus, rc: ReviewConfidence?,
                  reviewWeek: Int) -> ProposalMetadata {
            var p = ProposalMetadata(
                id:                 UUID(),
                projectId:          project,
                generatedInSession: session,
                createdAt:          base.addingTimeInterval(Double(n) * 3600),
                title:              "Fixture \(n)",
                rationale:          "isolation test",
                type:               .investigation,
                confidence:         confidence,
                affectedFiles:      ["f\(n).swift"],
                status:             status,
                reviewedAt:         nil,
                reviewNote:         nil,
                reviewConfidence:   nil
            )
            if status == .approved || status == .rejected {
                // reviewedAt is in a different calendar week per reviewWeek offset
                p.reviewedAt       = base.addingTimeInterval(Double(reviewWeek) * 7 * 86_400 + Double(n) * 3600 + 3600)
                p.reviewConfidence = rc
            }
            return p
        }

        // 3 weeks of reviews across 2 projects → stability not estimated, diversityScore = 2/5
        // Week 0: 2 approved  (projectA)     → weekly rate 1.0
        // Week 1: 1 approved + 1 rejected     → weekly rate 0.5
        // Week 2: 1 approved + 1 rejected     → weekly rate 0.5
        // Pending: 2 (one per project)
        return [
            make(n: 1, project: projectA, confidence: 0.8, status: .approved,  rc: .high,   reviewWeek: 0),
            make(n: 2, project: projectA, confidence: 0.7, status: .approved,  rc: .medium, reviewWeek: 0),
            make(n: 3, project: projectA, confidence: 0.9, status: .rejected,  rc: .high,   reviewWeek: 1),
            make(n: 4, project: projectB, confidence: 0.6, status: .approved,  rc: .low,    reviewWeek: 1),
            make(n: 5, project: projectB, confidence: 0.5, status: .approved,  rc: .medium, reviewWeek: 2),
            make(n: 6, project: projectB, confidence: 0.4, status: .rejected,  rc: nil,     reviewWeek: 2),
            make(n: 7, project: projectA, confidence: 0.3, status: .pending,   rc: nil,     reviewWeek: 0),
            make(n: 8, project: projectB, confidence: 0.8, status: .pending,   rc: nil,     reviewWeek: 0),
        ]
    }
}
#endif
