// ProposalModels.swift
// Phase 13B — Proposal artifact model
//
// Proposals are candidate mutations, not mutations.
// The journal records that they exist; user approval determines
// whether they ever become part of project history.
//
// Phase 13B: investigation / refactor / test / migration proposals (all .md)
// Phase 13C: patch proposals (.diff) — requires filesystem read access

import Foundation

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
    let id:            UUID
    let projectId:     UUID
    let sessionId:     UUID
    let createdAt:     Date

    let title:         String           // same discipline as checkpoint titles
    let rationale:     String           // why this proposal exists
    let type:          ProposalType
    let confidence:    Double           // 0.0–1.0 agent self-assessment
    let affectedFiles: [String]         // files the proposal would modify (not yet modified)

    var status:        ProposalStatus
    var reviewedAt:    Date?
    var reviewNote:    String?          // user's note on approval or rejection

    // Deterministic filename used as the artifact on disk
    var artifactFilename: String {
        let prefix = id.uuidString.prefix(8)
        return "\(prefix)-\(type.rawValue).\(type.fileExtension)"
    }
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
