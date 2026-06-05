// BackgroundScheduler.swift
// Phase 11 + 12.2 + 13A + 13B — Background Continuation
//
// Execution phases (automatic promotion based on evidence):
//
//   Phase 13A (read-only analysis):
//     Always runs. Produces a checkpoint describing findings.
//     Stop conditions 1–7 terminate the session safely.
//
//   Phase 13B (proposal generation — gated):
//     Activates when:
//       • backgroundCheckpointSpecificity ≥ 0.5  (quality proven)
//       • ≥ 5 prior background checkpoints       (sample established)
//     Produces a proposal artifact (ProposalStore) and references it in the checkpoint.
//     Still read-only — no filesystem writes outside Proposals/.
//
//   Phase 13C insertion point (apply approved patches):
//     Marked in code. Activates after 13B approval rate is established.

import Foundation
import UserNotifications

@MainActor
final class BackgroundScheduler {

    static let shared = BackgroundScheduler()

    private var scheduler: NSBackgroundActivityScheduler?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        let s = NSBackgroundActivityScheduler(identifier: "com.trevonbarbour.Mira.continuation")
        s.repeats          = true
        s.interval         = 30 * 60
        s.tolerance        = 5  * 60
        s.qualityOfService = .background
        s.schedule { completion in
            Task { @MainActor [weak self] in
                await self?.run()
                completion(.finished)
            }
        }
        scheduler = s
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }

    // MARK: - Phase 13A / 13B execution

    private func run() async {
        // Rule 1: user intent wins
        guard !ProjectEngine.shared.hasActiveUserSession else { return }

        // Rule 2: most recently interrupted project
        guard let project = ProjectEngine.shared.interruptedProjects()
            .max(by: { $0.lastActiveAt < $1.lastActiveAt }) else { return }

        // Stop condition 5: no checkpoints → insufficient context for analysis
        guard !project.checkpoints.isEmpty else { return }

        // Phase 12.2: coordinator routing
        let task = WorkTask(projectId: project.id, type: .continuation,
                            priority: 5, intent: .continuation)
        guard let assignment = AgentCoordinator.shared.assign(task: task) else { return }

        let persona = AgentCoordinator.shared.agents
            .first { $0.id == assignment.agentId }?.persona ?? .developer

        // Rule 3: idempotency guard
        guard let session = ProjectEngine.shared.startSession(
            projectId: project.id, persona: persona, trigger: .backgroundTimer
        ) else {
            AgentCoordinator.shared.complete(assignment: assignment)
            return
        }

        // ── Session ALWAYS closes (stop conditions 1–7) ───────────────────────
        var sessionSummary: String?
        var filesModified: [String] = []
        defer {
            ProjectEngine.shared.endSession(projectId: project.id, summary: sessionSummary)
            AgentCoordinator.shared.complete(assignment: assignment)
            ProjectEngine.shared.pendingContinuation =
                ProjectEngine.shared.project(id: project.id) ?? project
        }

        // Stop condition 6: no API key
        let apiKey = AppSecrets.anthropicAPIKey
        guard !apiKey.isEmpty else { return }

        let resumePrompt   = ProjectEngine.shared.buildResumePrompt(for: project)
        let sessionContext = ProjectEngine.shared.buildSessionContext(for: project)
        let service        = ClaudeService(apiKey: apiKey)

        // ── Phase 13A: background analysis (10-min timeout) ──────────────────
        let analysisResult: BackgroundWorkResult? = await withTaskGroup(of: BackgroundWorkResult?.self) { group in
            group.addTask {
                try? await service.backgroundAnalysis(resumePrompt: resumePrompt,
                                                       sessionContext: sessionContext)
            }
            group.addTask {   // Stop condition 4: 10-minute hard cap
                try? await Task.sleep(nanoseconds: UInt64(10 * 60) * 1_000_000_000)
                return nil
            }
            if let first = await group.next() { group.cancelAll(); return first }
            return nil
        }

        // Stop condition 7: nil result
        guard let analysis = analysisResult else { return }

        // Stop condition 2: blocker
        if analysis.shouldBlock {
            if let reason = analysis.blockReason {
                ProjectEngine.shared.markBlocked(id: project.id, reason: reason)
            }
            postNotification(title: "\(persona.displayName) is blocked on \(project.name)",
                             body: analysis.blockReason ?? "Needs your input before continuing.")
            return
        }

        // ── Phase 13B gate: promote from analysis-only to proposal generation ─
        // Requires: ≥5 prior background checkpoints AND rolling specificity ≥ 0.5.
        // This ensures 13B never activates on an untested agent.
        let phase13BActive = shouldRunPhase13B(for: project)

        if phase13BActive {
            // Phase 13B: generate a proposal artifact (also 10-min budget shared with analysis)
            let proposalResult: ProposalResult? = await withTaskGroup(of: ProposalResult?.self) { group in
                group.addTask {
                    try? await service.generateProposal(resumePrompt: resumePrompt,
                                                        sessionContext: sessionContext)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(5 * 60) * 1_000_000_000)
                    return nil
                }
                if let first = await group.next() { group.cancelAll(); return first }
                return nil
            }

            if let proposal = proposalResult, !proposal.shouldBlock,
               !proposal.title.isEmpty, !proposal.content.isEmpty {
                if let (_, relativePath) = try? ProposalStore.shared.create(
                    result: proposal,
                    projectId: project.id,
                    sessionId: session.id
                ) {
                    filesModified = [relativePath]
                }
            }
        }

        // ── Save checkpoint (Phase 13A always; 13B adds filesModified) ────────
        let checkpointSummary = filesModified.isEmpty
            ? analysis.checkpointSummary
            : analysis.checkpointSummary + " · Proposal saved."

        ProjectEngine.shared.saveCheckpoint(
            projectId:     project.id,
            title:         analysis.checkpointTitle,
            summary:       checkpointSummary,
            agentContext:  analysis.agentContext,
            filesModified: filesModified
        )
        sessionSummary = checkpointSummary

        // Quality monitoring: emit warning if rolling specificity drifts below 0.4
        if let updated = ProjectEngine.shared.project(id: project.id) {
            let score = ProjectEngine.shared.backgroundCheckpointSpecificity(for: updated)
            if score < 0.4 {
                ProjectEventBus.shared.post(ProjectEvent(
                    projectId: project.id,
                    type: .agentUpdate,
                    message: String(format: "⚠ Background checkpoint quality drifting (%.2f/1.0) — agent producing generic titles. Expand project context or add more specific criteria.", score)
                ))
            }
        }

        let notificationBody = filesModified.isEmpty
            ? analysis.checkpointTitle + " · background schedule"
            : analysis.checkpointTitle + " · proposal saved · background schedule"
        postNotification(title: "\(persona.displayName) checked in on \(project.name)",
                         body: notificationBody)

        // ── Phase 13C insertion point ─────────────────────────────────────────
        // After user approves a proposal via ProposalStore.update(status: .approved),
        // a subsequent session would call AgentService.run() to apply it.
        // Gate: ProposalStore.metrics(for:).approvalRate > 0 AND Phase 13C explicitly enabled.
    }

    // MARK: - Phase 13B gate

    /// Phase 13B activates when the background agent has demonstrated checkpoint quality:
    /// - At least 5 prior background checkpoints (sample established)
    /// - Rolling specificity ≥ 0.5 (quality proven above warning threshold)
    private func shouldRunPhase13B(for project: MiraProject) -> Bool {
        let bgCheckpointCount = project.sessions
            .filter { $0.trigger == .backgroundTimer }
            .flatMap { $0.checkpointIds }
            .count
        guard bgCheckpointCount >= 5 else { return false }
        let score = ProjectEngine.shared.backgroundCheckpointSpecificity(for: project)
        return score >= 0.5
    }

    // MARK: - Notification

    private func postNotification(title: String, body: String) {
        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { _ in }
    }
}
