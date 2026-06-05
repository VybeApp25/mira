// AgentCoordinator.swift
// Phase 12.1 — Arbitration layer (isolated, no ProjectEngine writes)
//
// Applies the five coordination rules deterministically.
// Does NOT call ProjectEngine.startSession — callers do that after receiving
// an AgentAssignment. The coordinator decides; the engine executes.
//
// Fixes applied in Phase 12.1.5:
//  • Task aging: effectivePriority() adds +1 per 5 min — prevents starvation
//  • PreemptionDecision: canPreempt returns score + reason string for explainability
//  • Assignment trace: assign() logs per-agent evaluation to stdout in DEBUG builds

import Foundation

@MainActor
final class AgentCoordinator: ObservableObject {

    static let shared = AgentCoordinator()

    var agents: [Agent] = Agent.builtIn

    @Published private(set) var activeAssignments: [AgentAssignment] = []
    /// Lightweight ring buffer of recent assignment decisions — debug builds only.
    /// Answers "why did this agent pick this project at 2:14 AM?" without persistence.
    @Published private(set) var coordinationTraces: [CoordinationTrace] = []

    private static let preemptionThreshold = 3
    var traceEnabled: Bool = true

    private init() {}

    // MARK: - Effective Priority (Fix 1 — anti-starvation aging)

    /// Adds a time-based boost so old tasks eventually outrank newer higher-priority ones.
    /// +1 effective priority per 5 minutes of age. Caps at +12 to prevent infinite escalation.
    func effectivePriority(for task: WorkTask) -> Int {
        let ageMinutes = Date().timeIntervalSince(task.createdAt) / 60.0
        let agingBoost = min(Int(ageMinutes / 5), 12)
        return task.priority + agingBoost
    }

    // MARK: - Agent Selection (Rules 2 + 4)

    func selectAgent(for task: WorkTask) -> Agent? {
        let (agent, _) = selectAgentExplained(for: task)
        return agent
    }

    // MARK: - Assignment (Rules 1 + 2 + 4, with trace)

    @discardableResult
    func assign(task: WorkTask) -> AgentAssignment? {
        guard task.status == .pending else {
            trace("[Coordinator] SKIP task=\(task.type.rawValue) — not pending (status=\(task.status.rawValue))")
            return nil
        }

        // Rule 1: project lock
        if activeAssignments.contains(where: { $0.projectId == task.projectId }) {
            trace("[Coordinator] BLOCK task=\(task.type.rawValue) project=\(task.projectId) — project already locked")
            return nil
        }

        let (agent, agentTrace) = selectAgentExplained(for: task)
        agentTrace.forEach { trace($0) }

        guard let agent else { return nil }

        let assignment = AgentAssignment(
            taskId:     task.id,
            agentId:    agent.id,
            projectId:  task.projectId,
            assignedAt: Date()
        )
        activeAssignments.append(assignment)
        trace("[Coordinator] ASSIGNED task=\(task.type.rawValue)[\(task.priority)] → \(agent.persona.displayName) (effPriority=\(effectivePriority(for: task)))")

        let ct = CoordinationTrace(taskId: task.id, projectId: task.projectId,
                                   intent: task.intent, assignedAgentId: agent.id,
                                   agentPersona: agent.persona, timestamp: Date())
        coordinationTraces.append(ct)
        if coordinationTraces.count > 100 { coordinationTraces.removeFirst() }

        return assignment
    }

    func complete(assignment: AgentAssignment) {
        activeAssignments.removeAll { $0.taskId == assignment.taskId }
        trace("[Coordinator] COMPLETE assignment taskId=\(assignment.taskId)")
    }

    func releaseProject(_ projectId: UUID) {
        activeAssignments.removeAll { $0.projectId == projectId }
        trace("[Coordinator] RELEASE project=\(projectId)")
    }

    // MARK: - Task Resolution (Rule 3, with aging)

    func resolve(tasks: [WorkTask]) -> [WorkTask] {
        tasks
            .filter { $0.status == .pending }
            .sorted { lhs, rhs in
                // Rule 3a: effective priority (includes aging boost)
                let lhsEff = effectivePriority(for: lhs)
                let rhsEff = effectivePriority(for: rhs)
                if lhsEff != rhsEff { return lhsEff > rhsEff }
                // Rule 3b: more recently active project goes next
                let lhsTime = ProjectEngine.shared.project(id: lhs.projectId)?.lastActiveAt ?? .distantPast
                let rhsTime = ProjectEngine.shared.project(id: rhs.projectId)?.lastActiveAt ?? .distantPast
                if lhsTime != rhsTime { return lhsTime > rhsTime }
                // Rule 3c: more checkpoints = more invested work = higher priority
                let lhsCP = ProjectEngine.shared.project(id: lhs.projectId)?.checkpoints.count ?? 0
                let rhsCP = ProjectEngine.shared.project(id: rhs.projectId)?.checkpoints.count ?? 0
                return lhsCP > rhsCP
            }
    }

    // MARK: - Preemption (Rule 5) — Fix 2: returns PreemptionDecision

    /// Returns a scored decision with a human-readable reason.
    /// score = priorityDelta + ageFactor; allowed when score > threshold.
    func canPreempt(incoming: WorkTask, current: WorkTask) -> PreemptionDecision {
        let priorityDelta = incoming.priority - current.priority
        let incomingAgeMinutes = Date().timeIntervalSince(incoming.createdAt) / 60.0
        let ageFactor = min(Int(incomingAgeMinutes / 5), 12)
        let score = priorityDelta + ageFactor
        let allowed = score > AgentCoordinator.preemptionThreshold

        let reason: String
        if !allowed {
            reason = "Score \(score) below threshold \(AgentCoordinator.preemptionThreshold) — queued"
        } else if priorityDelta > AgentCoordinator.preemptionThreshold {
            reason = "Higher priority (+\(priorityDelta) delta)"
        } else if ageFactor > 0 {
            reason = "Age-escalated priority (\(priorityDelta) base delta + \(ageFactor) aging)"
        } else {
            reason = "Combined score \(score) cleared threshold"
        }

        trace("[Coordinator] PREEMPT? incoming=\(incoming.type.rawValue)[\(incoming.priority)] vs current=\(current.type.rawValue)[\(current.priority)] → score=\(score) allowed=\(allowed) reason=\(reason)")
        return PreemptionDecision(allowed: allowed, reason: reason, score: score)
    }

    // MARK: - Convenience

    func assignedAgent(for projectId: UUID) -> Agent? {
        guard let assignment = activeAssignments.first(where: { $0.projectId == projectId }) else {
            return nil
        }
        return agents.first { $0.id == assignment.agentId }
    }

    // MARK: - Private helpers

    /// Returns the selected agent plus a per-agent evaluation trace for the assign() log.
    /// Phase 12.3: eligibility is now determined by intent-exact matching —
    /// agent must have task.intent.rawValue in its capabilityTags.
    private func selectAgentExplained(for task: WorkTask) -> (Agent?, [String]) {
        var log: [String] = []
        var preferred: Agent? = nil
        var fallback: Agent? = nil
        let wantedPersona = preferredPersona(for: task.type)

        for agent in agents {
            guard agent.capabilityTags.contains(task.intent.rawValue) else {
                log.append("[Coordinator] REJECT \(agent.persona.displayName) — intent '\(task.intent.rawValue)' not in capabilities")
                continue
            }
            guard !activeAssignments.contains(where: { $0.agentId == agent.id }) else {
                log.append("[Coordinator] REJECT \(agent.persona.displayName) — already assigned")
                continue
            }
            log.append("[Coordinator] ELIGIBLE \(agent.persona.displayName)")
            if agent.persona == wantedPersona { preferred = agent }
            else if fallback == nil { fallback = agent }
        }

        let selected = preferred ?? fallback
        if selected == nil {
            log.append("[Coordinator] NO AGENT — no eligible agent for task=\(task.type.rawValue) intent=\(task.intent.rawValue)")
        }
        return (selected, log)
    }

    private func preferredPersona(for type: WorkTaskType) -> AgentPersona {
        switch type {
        case .implementation, .continuation: return .developer
        case .verification:                  return .tester
        case .research, .review:             return .researcher
        }
    }

    private func trace(_ message: String) {
        #if DEBUG
        guard traceEnabled else { return }
        print(message)
        #endif
    }
}

#if DEBUG
extension AgentCoordinator {
    /// Returns a fresh coordinator instance for simulation and testing.
    /// Never use this in production code — use AgentCoordinator.shared.
    /// Returns a fresh coordinator with trace silenced — enable explicitly per-phase.
    /// Pass `agents` to override the default roster (useful for before/after comparisons).
    static func makeForTesting(agents: [Agent]? = nil) -> AgentCoordinator {
        let c = AgentCoordinator()
        c.traceEnabled = false
        if let agents { c.agents = agents }
        return c
    }
}
#endif
