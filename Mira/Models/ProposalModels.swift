// ProposalModels.swift
// Phase 13B — Proposal artifact model
//
// Proposals are candidate mutations, not mutations.
// The journal records that they exist; user approval determines
// whether they ever become part of project history.
//
// Phase 13B: investigation / refactor / test / migration proposals (all .md)
// Phase 13C: patch proposals (.diff) — requires filesystem read access
//
// Session-mode invariant (enforced by ProposalStore):
//   A session may generate proposals OR apply proposals — never both.
//   Application requires generatedInSession != currentSessionId.

import Foundation

// MARK: - ProposalError

enum ProposalError: Error, LocalizedError {
    case sameSessionApplication(sessionId: UUID)
    case sessionModeConflict(sessionId: UUID, existing: ProposalSessionMode)

    var errorDescription: String? {
        switch self {
        case .sameSessionApplication(let id):
            return "Proposal cannot be applied in the same session that generated it (session \(id.uuidString.prefix(8)))."
        case .sessionModeConflict(let id, let mode):
            return "Session \(id.uuidString.prefix(8)) is already in .\(mode) mode — cannot switch within a session."
        }
    }
}

// MARK: - ProposalSessionMode

/// Enforces that a session either generates or applies proposals, never both.
/// ProposalStore tracks this per session ID in-memory for the app lifetime.
enum ProposalSessionMode: String {
    case generating
    case applying
}

// MARK: - ReviewConfidence

/// Human certainty at the moment of approval or rejection.
/// Stored alongside the decision so weighted approval rate can be computed
/// separately from raw approval rate — a low-confidence 80% approval is weaker
/// evidence than a high-confidence 80% approval.
enum ReviewConfidence: Int, Codable, CaseIterable {
    case low    = 1
    case medium = 2
    case high   = 3

    var label: String {
        switch self { case .low: return "Low"; case .medium: return "Medium"; case .high: return "High" }
    }

    var weight: Double { Double(rawValue) }
}

// MARK: - ProposalStatus

enum ProposalStatus: String, Codable {
    case pending     // created by agent, awaiting user review
    case approved    // user approved — ready to apply in Phase 13C
    case rejected    // user rejected — preserved for audit
    case superseded  // replaced by a newer proposal targeting the same files
}

// MARK: - ProposalType

enum ProposalType: String, Codable, CaseIterable {
    case investigation = "investigation"  // Detailed analysis findings
    case refactor      = "refactor"       // Structural / architectural recommendation
    case test          = "test"           // Suggested test cases to write
    case migration     = "migration"      // Multi-step change plan
    case patch         = "patch"          // Phase 13C: actual diff (requires filesystem reads)

    var fileExtension: String {
        // Phase 13B produces markdown; patch diff enabled in Phase 13C
        self == .patch ? "diff" : "md"
    }

    var displayName: String {
        switch self {
        case .investigation: return "Investigation"
        case .refactor:      return "Refactor"
        case .test:          return "Test Proposal"
        case .migration:     return "Migration Plan"
        case .patch:         return "Patch"
        }
    }
}

// MARK: - ProposalMetadata

/// Sidecar record stored alongside each proposal artifact in Proposals/<project-id>/metadata.json.
/// Journal checkpoints reference the artifact path — metadata provides the searchable index.
struct ProposalMetadata: Identifiable, Codable {
    let id:                  UUID
    let projectId:           UUID
    /// The session that generated this proposal. Phase 13C must verify its apply session differs.
    let generatedInSession:  UUID
    let createdAt:           Date

    let title:               String     // same discipline as checkpoint titles
    let rationale:           String     // why this proposal exists
    let type:                ProposalType
    let confidence:          Double     // 0.0–1.0 agent self-assessment
    let affectedFiles:       [String]   // files the proposal would modify (not yet modified)

    var status:              ProposalStatus
    var reviewedAt:          Date?
    var reviewNote:          String?          // user's note on approval or rejection
    var reviewConfidence:    ReviewConfidence? // how certain the reviewer was — nil = not recorded

    // Deterministic filename used as the artifact on disk
    var artifactFilename: String {
        let prefix = id.uuidString.prefix(8)
        return "\(prefix)-\(type.rawValue).\(type.fileExtension)"
    }
}

// MARK: - EvidenceStrength

/// Global readiness signal derived from sample size, project diversity, and review coverage.
/// A gate should never appear "passed" when evidence strength is Weak or Emerging.
/// Evidence quality matters as much as evidence value.
enum EvidenceStrength: Int, Comparable, CaseIterable {
    case weak     = 1   // < 10 reviewed, or single project
    case emerging = 2   // 10–19 reviewed, or 1 project, or low coverage
    case moderate = 3   // ≥ 20 reviewed, ≥ 2 projects, ≥ 60% coverage
    case strong   = 4   // ≥ 50 reviewed, ≥ 3 projects, ≥ 80% coverage, all signals populated

    static func < (lhs: EvidenceStrength, rhs: EvidenceStrength) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .weak:     return "Weak"
        case .emerging: return "Emerging"
        case .moderate: return "Moderate"
        case .strong:   return "Strong"
        }
    }

    var detail: String {
        switch self {
        case .weak:     return "< 10 reviewed or single project — no signal yet"
        case .emerging: return "Building sample — metrics visible but not actionable"
        case .moderate: return "Sufficient for threshold evaluation"
        case .strong:   return "Statistically robust across projects"
        }
    }

    /// Gate conditions are only evaluated when evidence is at least this strength.
    static let minimumForGate: EvidenceStrength = .moderate
}

// MARK: - CalibrationBucket

/// One 10%-wide confidence bucket containing the proposals whose agent confidence fell in that range.
/// Only approved/rejected proposals are counted — pending and superseded are excluded.
///
/// A calibrated system trends toward approvalRate ≈ confidenceMidpoint.
/// calibrationError > 0 means the model is under-confident (it's right more often than it claims).
/// calibrationError < 0 means the model is over-confident (it claims certainty it hasn't earned).
struct CalibrationBucket: Identifiable {
    /// Lower bound of the 10%-wide range (e.g. 0.80 for the 80–89% bucket).
    let lowerBound:           Double
    let proposalCount:        Int
    /// approved / (approved + rejected) within this bucket.
    let approvalRate:         Double
    /// Approval rate weighted by reviewer confidence — nil when no reviewer confidence recorded.
    let weightedApprovalRate: Double?
    /// approvalRate − confidenceMidpoint. Positive = under-confident. Negative = over-confident.
    let calibrationError:     Double

    var id: Double { lowerBound }

    var rangeLabel: String {
        String(format: "%.0f–%.0f%%", lowerBound * 100, (lowerBound + 0.10) * 100)
    }

    var confidenceMidpoint: Double { lowerBound + 0.05 }
}

// MARK: - ProposalResult (parsed from ClaudeService.generateProposal)

/// Transient output from the background proposal generation pass.
/// Caller converts this into a ProposalMetadata + artifact file via ProposalStore.
struct ProposalResult {
    let type:          ProposalType
    let title:         String
    let rationale:     String
    let content:       String    // full markdown (or diff in Phase 13C)
    let confidence:    Double
    let affectedFiles: [String]
    let shouldBlock:   Bool
    let blockReason:   String?
}
