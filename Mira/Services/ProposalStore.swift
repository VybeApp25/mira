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
        let metadata = ProposalMetadata(
            id:            UUID(),
            projectId:     projectId,
            sessionId:     sessionId,
            createdAt:     Date(),
            title:         result.title,
            rationale:     result.rationale,
            type:          result.type,
            confidence:    result.confidence,
            affectedFiles: result.affectedFiles,
            status:        .pending,
            reviewedAt:    nil,
            reviewNote:    nil
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
                status: ProposalStatus, note: String? = nil) {
        var proposals = load(for: projectId)
        guard let idx = proposals.firstIndex(where: { $0.id == proposalId }) else { return }
        proposals[idx].status    = status
        proposals[idx].reviewedAt = Date()
        proposals[idx].reviewNote = note

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

    // MARK: - Metrics (Phase 13B → 13C promotion gate)

    struct Metrics {
        let total:        Int
        let pending:      Int
        let approved:     Int
        let rejected:     Int
        let superseded:   Int
        let approvalRate: Double   // approved / (approved + rejected), NaN when no reviews yet
    }

    func metrics(for projectId: UUID) -> Metrics {
        let all       = load(for: projectId)
        let approved  = all.filter { $0.status == .approved  }.count
        let rejected  = all.filter { $0.status == .rejected  }.count
        let reviewed  = approved + rejected
        return Metrics(
            total:        all.count,
            pending:      all.filter { $0.status == .pending    }.count,
            approved:     approved,
            rejected:     rejected,
            superseded:   all.filter { $0.status == .superseded }.count,
            approvalRate: reviewed == 0 ? Double.nan : Double(approved) / Double(reviewed)
        )
    }
}
