// ProposalStore.swift
// Phase 13B — Proposal artifact management
//
// Manages ~/Library/Application Support/Mira/Proposals/<project-id>/
// Proposals are never inside the project's actual source tree —
// they are candidate mutations referenced by journal checkpoints.

import Foundation

@MainActor
final class ProposalStore: ObservableObject {

    static let shared = ProposalStore()
    private init() {}

    // In-memory session mode registry.
    // Once a session is marked .generating or .applying it cannot switch.
    private var sessionModes: [UUID: ProposalSessionMode] = [:]

    /// Call before generating a proposal in a session.
    /// Throws `.sessionModeConflict` if the session is already in .applying mode.
    func claimGenerating(sessionId: UUID) throws {
        if let existing = sessionModes[sessionId], existing != .generating {
            throw ProposalError.sessionModeConflict(sessionId: sessionId, existing: existing)
        }
        sessionModes[sessionId] = .generating
    }

    /// Call before applying a proposal in a session.
    /// Throws `.sameSessionApplication` if the session generated the proposal.
    /// Throws `.sessionModeConflict` if the session is already in .generating mode.
    func claimApplying(proposal: ProposalMetadata, inSession sessionId: UUID) throws {
        guard proposal.generatedInSession != sessionId else {
            throw ProposalError.sameSessionApplication(sessionId: sessionId)
        }
        if let existing = sessionModes[sessionId], existing != .applying {
            throw ProposalError.sessionModeConflict(sessionId: sessionId, existing: existing)
        }
        sessionModes[sessionId] = .applying
    }

    func sessionMode(for sessionId: UUID) -> ProposalSessionMode? {
        sessionModes[sessionId]
    }

    // MARK: - Directories

    /// Returns (and creates if needed) the proposals directory for a project.
    func directory(for projectId: UUID) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support
            .appendingPathComponent("Mira",    isDirectory: true)
            .appendingPathComponent("Proposals", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func metadataURL(for projectId: UUID) -> URL {
        directory(for: projectId).appendingPathComponent("metadata.json")
    }

    // MARK: - Create

    /// Writes the artifact to disk and appends its metadata to metadata.json.
    /// Returns the path relative to the Mira support root (used as filesModified in checkpoints).
    @discardableResult
    func create(result: ProposalResult,
                projectId: UUID,
                sessionId: UUID) throws -> (metadata: ProposalMetadata, relativePath: String) {
        try claimGenerating(sessionId: sessionId)
        let metadata = ProposalMetadata(
            id:                 UUID(),
            projectId:          projectId,
            generatedInSession: sessionId,
            createdAt:          Date(),
            title:              result.title,
            rationale:          result.rationale,
            type:               result.type,
            confidence:         result.confidence,
            affectedFiles:      result.affectedFiles,
            status:             .pending,
            reviewedAt:         nil,
            reviewNote:         nil
        )

        let dir         = directory(for: projectId)
        let artifactURL = dir.appendingPathComponent(metadata.artifactFilename)
        try result.content.write(to: artifactURL, atomically: true, encoding: .utf8)

        var existing = load(for: projectId)
        existing.append(metadata)
        let data = try JSONEncoder().encode(existing)
        try data.write(to: metadataURL(for: projectId), options: .atomic)

        // Relative path used as the filesModified entry in the journal checkpoint
        let relativePath = "Proposals/\(projectId.uuidString)/\(metadata.artifactFilename)"
        return (metadata, relativePath)
    }

    // MARK: - Read

    func load(for projectId: UUID) -> [ProposalMetadata] {
        guard let data   = try? Data(contentsOf: metadataURL(for: projectId)),
              let decoded = try? JSONDecoder().decode([ProposalMetadata].self, from: data) else { return [] }
        return decoded
    }

    func pending(for projectId: UUID) -> [ProposalMetadata] {
        load(for: projectId).filter { $0.status == .pending }
    }

    func artifactContent(for proposal: ProposalMetadata) -> String? {
        let url = directory(for: proposal.projectId).appendingPathComponent(proposal.artifactFilename)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Update Status

    func update(proposalId: UUID, projectId: UUID,
                status: ProposalStatus,
                confidence: ReviewConfidence? = nil,
                note: String? = nil) {
        var proposals = load(for: projectId)
        guard let idx = proposals.firstIndex(where: { $0.id == proposalId }) else { return }
        proposals[idx].status           = status
        proposals[idx].reviewedAt       = Date()
        proposals[idx].reviewNote       = note
        proposals[idx].reviewConfidence = confidence

        // Approval supersedes any other pending proposal that touches the same files
        if status == .approved {
            let approved = Set(proposals[idx].affectedFiles)
            for i in proposals.indices where i != idx && proposals[i].status == .pending {
                if !Set(proposals[i].affectedFiles).isDisjoint(with: approved) {
                    proposals[i].status     = .superseded
                    proposals[i].reviewedAt = Date()
                    proposals[i].reviewNote = "Superseded by approved proposal \(proposalId.uuidString.prefix(8))"
                }
            }
        }

        if let data = try? JSONEncoder().encode(proposals) {
            try? data.write(to: metadataURL(for: projectId), options: .atomic)
        }
    }

    // MARK: - Outcome tracking (Phase 15)

    /// Appends one assessment to a proposal's outcome sequence. Never overwrites.
    func appendOutcome(_ assessment: OutcomeAssessment, to proposalId: UUID, projectId: UUID) {
        var proposals = load(for: projectId)
        guard let idx = proposals.firstIndex(where: { $0.id == proposalId }) else { return }
        proposals[idx].outcomes.append(assessment)
        if let data = try? JSONEncoder().encode(proposals) {
            try? data.write(to: metadataURL(for: projectId), options: .atomic)
        }
    }

    /// Funnel counts across a set of projects.
    struct OutcomeFunnel {
        let approved:      Int
        let implemented:   Int   // latest assessment has adoptionStatus == .implemented
        let improved:      Int   // implemented AND latest impact == .improved
        let notReverted:   Int   // improved AND latest regret == .none
    }

    func outcomeFunnel(for projects: [MiraProject]) -> OutcomeFunnel {
        var approved = 0, implemented = 0, improved = 0, notReverted = 0
        for project in projects {
            for p in load(for: project.id) where p.status == .approved {
                approved += 1
                guard let summary = OutcomeSummary.compute(from: p.outcomes,
                                                           reviewedAt: p.reviewedAt) else { continue }
                guard summary.currentAdoption == .implemented else { continue }
                implemented += 1
                guard summary.currentImpact == .improved else { continue }
                improved += 1
                if summary.currentRegret == .none { notReverted += 1 }
            }
        }
        return OutcomeFunnel(approved: approved, implemented: implemented,
                             improved: improved, notReverted: notReverted)
    }

    // MARK: - Metrics (Phase 13B → 13C promotion gate)

    /// Stale threshold: pending proposals older than this are counted as "never reviewed."
    static let stalePendingThreshold: TimeInterval = 7 * 24 * 60 * 60   // 7 days

    struct Metrics {
        let total:                Int
        let pending:              Int
        let approved:             Int
        let rejected:             Int
        let superseded:           Int
        /// approved / (approved + rejected). NaN when no reviews yet.
        let approvalRate:         Double
        /// rejected / (approved + rejected). NaN when no reviews yet.
        let rejectionRate:        Double
        /// superseded / total (all proposals, not just reviewed). NaN when total == 0.
        let supersededRate:       Double
        /// Mean time from generatedAt → reviewedAt across all reviewed proposals.
        let averageReviewLatency: TimeInterval?
        /// Median time from generatedAt → reviewedAt across all reviewed proposals.
        let medianReviewLatency:  TimeInterval?
        /// Pending proposals older than stalePendingThreshold — the "never reviewed" signal.
        let stalePendingCount:    Int
        /// Age of the oldest pending proposal. nil when no pending proposals.
        let oldestPendingAge:     TimeInterval?
        /// Σ(approved_i × confidenceWeight_i) / Σ(confidenceWeight_i) across approvals with recorded confidence.
        /// NaN when no approvals have confidence recorded. Distinct from approvalRate: a 80% approval
        /// at low confidence is weaker evidence than 80% at high confidence.
        let weightedApprovalRate: Double
        /// Expected Calibration Error converted to a 0–1 score: 1.0 = perfect calibration.
        /// NaN when fewer than 2 populated buckets or fewer than 5 reviewed proposals.
        /// A miscalibrated model has lower scores; a well-calibrated model trends toward 1.0.
        let calibrationScore: Double
        /// (approved + rejected) / total. NaN when total == 0.
        /// Measures review engagement — a system with 90% approval but 10% coverage is not trustworthy.
        let reviewCoverage: Double
        /// Composite signal: approvalRate × reviewCoverage × weightedApprovalRate × calibrationFactor.
        /// Factors with insufficient data are omitted from the product (partial score).
        /// isPartialTrustworthiness indicates whether all 4 factors contributed.
        /// NOT a gate signal — read alongside individual components, never instead of them.
        /// Calibration without accuracy is useless. Accuracy without calibration is dangerous.
        let trustworthinessIndex:      Double
        let isPartialTrustworthiness:  Bool   // true when weightedApproval or calibration had no data
        /// Count of approvals with reviewConfidence recorded — sample size for weightedApprovalRate.
        let approvedWithConfidenceCount: Int
    }

    /// Total proposal count across a set of projects — used by SettingsView badge.
    func globalProposalCount(for projects: [MiraProject]) -> Int {
        projects.reduce(0) { $0 + load(for: $1.id).count }
    }

    func metrics(for projectId: UUID) -> Metrics {
        let all       = load(for: projectId)
        let approved  = all.filter { $0.status == .approved  }.count
        let rejected  = all.filter { $0.status == .rejected  }.count
        let reviewed  = approved + rejected
        let now       = Date()

        let latencies: [TimeInterval] = all.compactMap { p in
            guard let r = p.reviewedAt else { return nil }
            return r.timeIntervalSince(p.createdAt)
        }
        let avgLatency: TimeInterval? = latencies.isEmpty ? nil
            : latencies.reduce(0, +) / Double(latencies.count)
        let medianLatency: TimeInterval? = latencies.isEmpty ? nil
            : { let s = latencies.sorted(); return s[s.count / 2] }()

        let pendingProposals = all.filter { $0.status == .pending }
        let stale  = pendingProposals.filter { now.timeIntervalSince($0.createdAt) > Self.stalePendingThreshold }.count
        let oldest = pendingProposals.map { now.timeIntervalSince($0.createdAt) }.max()

        // Weighted approval: only from approved proposals with recorded confidence.
        // Σ(weight) / Σ(weight_max) — normalised so high-confidence 100% = 1.0, low-confidence 100% < 1.0.
        let approvedWithConfidence = all.filter { $0.status == .approved && $0.reviewConfidence != nil }
        let weightedApproval: Double = {
            guard !approvedWithConfidence.isEmpty else { return Double.nan }
            let totalWeight    = approvedWithConfidence.reduce(0.0) { $0 + ($1.reviewConfidence?.weight ?? 0) }
            let maxWeight      = Double(approvedWithConfidence.count) * ReviewConfidence.high.weight
            return totalWeight / maxWeight
        }()

        let buckets = buildCalibrationBuckets(from: all)
        let ece: Double = {
            let reviewedCount = all.filter { $0.status == .approved || $0.status == .rejected }.count
            guard buckets.count >= 2, reviewedCount >= 5 else { return Double.nan }
            return buckets.reduce(0.0) { sum, b in
                sum + abs(b.calibrationError) * (Double(b.proposalCount) / Double(reviewedCount))
            }
        }()
        let calibScore = ece.isNaN ? Double.nan : max(0, 1.0 - ece)

        let approvalRate  = reviewed == 0 ? Double.nan : Double(approved) / Double(reviewed)
        let coverageRate  = all.isEmpty   ? Double.nan : Double(reviewed) / Double(all.count)

        // Trustworthiness: product of available factors in [0,1].
        // Accuracy (approvalRate × coverage) is always the base — calibration and review
        // confidence enrich it when available but cannot substitute for it.
        let approvedWithConfidenceCount = approvedWithConfidence.count

        let (trustScore, isPartial): (Double, Bool) = {
            guard !approvalRate.isNaN, !coverageRate.isNaN else { return (Double.nan, false) }
            var product = approvalRate * coverageRate
            var partial = false
            if !weightedApproval.isNaN { product *= weightedApproval } else { partial = true }
            if !calibScore.isNaN       { product *= calibScore       } else { partial = true }
            return (product, partial)
        }()

        return Metrics(
            total:                        all.count,
            pending:                      pendingProposals.count,
            approved:                     approved,
            rejected:                     rejected,
            superseded:                   all.filter { $0.status == .superseded }.count,
            approvalRate:                 approvalRate,
            rejectionRate:                reviewed == 0 ? Double.nan : Double(rejected) / Double(reviewed),
            supersededRate:               all.isEmpty ? Double.nan : Double(all.filter { $0.status == .superseded }.count) / Double(all.count),
            averageReviewLatency:         avgLatency,
            medianReviewLatency:          medianLatency,
            stalePendingCount:            stale,
            oldestPendingAge:             oldest,
            weightedApprovalRate:         weightedApproval,
            calibrationScore:             calibScore,
            reviewCoverage:               coverageRate,
            trustworthinessIndex:         trustScore,
            isPartialTrustworthiness:     isPartial,
            approvedWithConfidenceCount:  approvedWithConfidenceCount
        )
    }

    // MARK: - Global evidence dimensions + regression lock

    private let delegationKey     = "mira.delegation.authorized"
    private let lastStrengthKey   = "mira.evidence.lastStrength"

    @Published private(set) var delegationAuthorized: Bool = false
    private var lastObservedStrength: EvidenceStrength = .weak

    func loadDelegationState() {
        delegationAuthorized  = UserDefaults.standard.bool(forKey: delegationKey)
        let raw = UserDefaults.standard.integer(forKey: lastStrengthKey)
        lastObservedStrength  = EvidenceStrength(rawValue: raw) ?? .weak
    }

    /// Call after computing evidence dimensions. Auto-revokes delegation on regression.
    func observeEvidenceStrength(_ strength: EvidenceStrength) {
        defer {
            lastObservedStrength = strength
            UserDefaults.standard.set(strength.rawValue, forKey: lastStrengthKey)
        }
        if lastObservedStrength == .strong && strength < .strong && delegationAuthorized {
            delegationAuthorized = false
            UserDefaults.standard.set(false, forKey: delegationKey)
        }
    }

    /// Explicit human grant — only valid when current evidence strength is .strong.
    func grantDelegation(currentStrength: EvidenceStrength) {
        guard currentStrength == .strong else { return }
        delegationAuthorized = true
        UserDefaults.standard.set(true, forKey: delegationKey)
    }

    /// Whether evidence has ever been strong enough to earn delegation (persisted).
    var hadReachedStrong: Bool { UserDefaults.standard.integer(forKey: lastStrengthKey) >= EvidenceStrength.strong.rawValue }

    /// Computes four independent evidence dimensions and derives overall strength.
    /// Geometric mean prevents any single axis from dominating.
    func globalEvidenceDimensions(for projects: [MiraProject]) -> EvidenceDimensions {
        let allMetrics          = projects.map { metrics(for: $0.id) }
        let totalReviewed       = allMetrics.reduce(0) { $0 + $1.approved + $1.rejected }
        let projectsWithReviews = allMetrics.filter { $0.approved + $0.rejected > 0 }.count
        let totalProposals      = allMetrics.reduce(0) { $0 + $1.total }

        let volumeScore    = min(Double(totalReviewed) / 50.0, 1.0)
        let diversityScore = min(Double(projectsWithReviews) / 5.0, 1.0)
        let coverageScore  = totalProposals == 0 ? 0.0 : min(Double(totalReviewed) / Double(totalProposals), 1.0)

        let allProposals = projects.flatMap { load(for: $0.id) }
        let (stabilityScore, stabilityIsEstimated) = computeStabilityScore(from: allProposals)

        return EvidenceDimensions(
            volumeScore:          volumeScore,
            diversityScore:       diversityScore,
            coverageScore:        coverageScore,
            stabilityScore:       stabilityScore,
            stabilityIsEstimated: stabilityIsEstimated
        )
    }

    /// Convenience accessor kept for compatibility — use globalEvidenceDimensions for full detail.
    func globalEvidenceStrength(for projects: [MiraProject]) -> EvidenceStrength {
        globalEvidenceDimensions(for: projects).strength
    }

    // MARK: - Stability score

    private func computeStabilityScore(from proposals: [ProposalMetadata]) -> (Double, Bool) {
        let reviewed = proposals.filter { ($0.status == .approved || $0.status == .rejected) && $0.reviewedAt != nil }
        guard reviewed.count >= 2 else { return (0.5, true) }

        var weekBuckets: [Date: (approved: Int, total: Int)] = [:]
        let cal = Calendar.current
        for p in reviewed {
            guard let d = p.reviewedAt else { continue }
            let weekStart = cal.dateInterval(of: .weekOfYear, for: d)?.start ?? d
            weekBuckets[weekStart, default: (0, 0)].total += 1
            if p.status == .approved { weekBuckets[weekStart, default: (0, 0)].approved += 1 }
        }

        guard weekBuckets.count >= 2 else { return (0.5, true) }

        let rates  = weekBuckets.values.map { Double($0.approved) / Double($0.total) }
        let mean   = rates.reduce(0, +) / Double(rates.count)
        let stdDev = sqrt(rates.map { pow($0 - mean, 2) }.reduce(0, +) / Double(rates.count))
        // stdDev 0 = perfectly stable (1.0); stdDev 0.40+ = completely unstable (0)
        return (max(0, 1.0 - stdDev / 0.40), false)
    }

    // MARK: - Calibration buckets

    /// Groups approved/rejected proposals into 10%-wide confidence buckets and computes
    /// per-bucket approval rate and calibration error. Empty buckets are omitted.
    func calibration(for projectId: UUID) -> [CalibrationBucket] {
        buildCalibrationBuckets(from: load(for: projectId))
    }

    private func buildCalibrationBuckets(from proposals: [ProposalMetadata]) -> [CalibrationBucket] {
        let reviewed = proposals.filter { $0.status == .approved || $0.status == .rejected }
        guard !reviewed.isEmpty else { return [] }

        // Group into 10% buckets: [0.0,0.1), [0.1,0.2), ..., [0.9,1.0]
        var groups: [Int: [ProposalMetadata]] = [:]
        for p in reviewed {
            let bucket = min(Int(p.confidence * 10), 9)   // 0...9
            groups[bucket, default: []].append(p)
        }

        return groups.keys.sorted().compactMap { bucketIdx -> CalibrationBucket? in
            let items = groups[bucketIdx] ?? []
            guard !items.isEmpty else { return nil }
            let lowerBound  = Double(bucketIdx) / 10.0
            let midpoint    = lowerBound + 0.05
            let approvedN   = items.filter { $0.status == .approved }.count
            let approvalRate = Double(approvedN) / Double(items.count)

            // Weighted approval rate using reviewer confidence (nil if none recorded)
            let withConfidence = items.filter { $0.status == .approved && $0.reviewConfidence != nil }
            let weighted: Double? = withConfidence.isEmpty ? nil : {
                let totalW = withConfidence.reduce(0.0) { $0 + ($1.reviewConfidence?.weight ?? 0) }
                let maxW   = Double(withConfidence.count) * ReviewConfidence.high.weight
                return totalW / maxW
            }()

            return CalibrationBucket(
                lowerBound:           lowerBound,
                proposalCount:        items.count,
                approvalRate:         approvalRate,
                weightedApprovalRate: weighted,
                calibrationError:     approvalRate - midpoint
            )
        }
        .sorted { $0.lowerBound > $1.lowerBound }   // highest confidence first
    }
}
