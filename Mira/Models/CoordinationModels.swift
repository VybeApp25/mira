// CoordinationModels.swift
// Phase 12.1 — Coordination Core (isolated, no ProjectEngine writes)
//
// These types define the arbitration layer: work intent, worker identity,
// and assignment records. They do NOT touch ProjectEngine or persistence.

import Foundation

// MARK: - WorkIntent

/// Explicit assignment target for a task — what kind of work is being requested.
/// Used by AgentCoordinator for exact capability matching: an agent is eligible
/// only if its capabilityTags contains intent.rawValue.
///
/// Intent is derived from WorkTaskType by default but can be overridden when the
/// task creator has more precise knowledge (e.g. a continuation task that specifically
/// needs a tester, not a developer).
enum WorkIntent: String, Codable {
    case implementation = "implementation"
    case verification   = "verification"
    case research       = "research"
    case review         = "review"
    case continuation   = "continuation"
}

extension WorkIntent {
    init(from type: WorkTaskType) {
        switch type {
        case .implementation: self = .implementation
        case .verification:   self = .verification
        case .research:       self = .research
        case .review:         self = .review
        case .continuation:   self = .continuation
        }
    }
}

// MARK: - WorkTaskType

enum WorkTaskType: String, Codable, CaseIterable {
    case continuation    // resume interrupted project (background or user-triggered)
    case implementation  // build / write code / produce artifacts
    case verification    // test / validate / qa
    case research        // investigate / analyze / survey
    case review          // audit / code review / doc review
}

// MARK: - WorkTaskStatus

enum WorkTaskStatus: String, Codable {
    case pending    // created, awaiting coordinator assignment
    case assigned   // coordinator selected an agent, session not yet started
    case active     // ProjectEngine session is live
    case completed  // session ended
    case cancelled  // explicitly cancelled before or during execution
}

// MARK: - WorkTask

/// A unit of work intent. Created by the scheduler, a tool call, or the UI.
/// Never mutates ProjectEngine — it describes *what should happen*, not *what did*.
struct WorkTask: Identifiable {
    let id:                   UUID
    let projectId:            UUID
    let type:                 WorkTaskType
    let intent:               WorkIntent     // explicit assignment target (derived from type if not set)
    let priority:             Int            // higher = more urgent; 0 = normal, 10 = critical
    let requiredCapabilities: Set<String>    // retained for future decomposition; not used for routing
    var status:               WorkTaskStatus
    let createdAt:            Date

    init(projectId: UUID,
         type: WorkTaskType,
         priority: Int = 0,
         requiredCapabilities: Set<String> = [],
         intent: WorkIntent? = nil,
         createdAt: Date = Date()) {
        self.id                   = UUID()
        self.projectId            = projectId
        self.type                 = type
        self.intent               = intent ?? WorkIntent(from: type)
        self.priority             = priority
        self.requiredCapabilities = requiredCapabilities
        self.status               = .pending
        self.createdAt            = createdAt
    }
}

// MARK: - PreemptionDecision

/// Result of AgentCoordinator.canPreempt — carries the score and a human-readable
/// explanation so Phase 13 can surface "why did Mira interrupt that task?" answers.
struct PreemptionDecision {
    let allowed: Bool
    let reason:  String
    let score:   Int
}

// MARK: - Agent

/// A stateless worker identity. Agents hold no state across sessions.
/// All memory is journal-derived — pulled from ProjectEngine at execution time.
struct Agent: Identifiable {
    let id:              UUID
    let persona:         AgentPersona
    let capabilityTags:  Set<String>
}

extension Agent {
    /// Fixed built-in agents. UUIDs are stable across runs — do not change.
    static let builtIn: [Agent] = [
        Agent(
            id: UUID(uuidString: "00000000-0000-0000-0001-000000000001")!,
            persona: .developer,
            capabilityTags: ["implementation", "refactoring", "debugging",
                             "architecture", "continuation"]
        ),
        Agent(
            id: UUID(uuidString: "00000000-0000-0000-0001-000000000002")!,
            persona: .tester,
            capabilityTags: ["verification", "debugging", "review",
                             "testing", "continuation"]
        ),
        Agent(
            id: UUID(uuidString: "00000000-0000-0000-0001-000000000003")!,
            persona: .researcher,
            capabilityTags: ["research", "review", "analysis",
                             "investigation", "continuation"]
        ),
        Agent(
            id: UUID(uuidString: "00000000-0000-0000-0001-000000000004")!,
            persona: .writer,
            capabilityTags: ["documentation", "writing", "drafting",
                             "reporting", "continuation"]
        ),
        // Option A expansion: second Developer + second Tester
        // Added after Phase 12.1.5 chaos stress revealed capability-gap starvation
        // on verification and implementation/debugging tasks.
        Agent(
            id: UUID(uuidString: "00000000-0000-0000-0001-000000000005")!,
            persona: .developer,
            capabilityTags: ["implementation", "refactoring", "debugging",
                             "architecture", "continuation"]
        ),
        Agent(
            id: UUID(uuidString: "00000000-0000-0000-0001-000000000006")!,
            persona: .tester,
            capabilityTags: ["verification", "debugging", "review",
                             "testing", "continuation"]
        ),
    ]
}

// MARK: - AgentAssignment

/// Records that the coordinator chose a specific agent for a specific task.
/// Created by AgentCoordinator.assign(task:) — not persisted.
struct AgentAssignment {
    let taskId:      UUID
    let agentId:     UUID
    let projectId:   UUID
    let assignedAt:  Date
}

// MARK: - BackgroundWorkResult

/// Structured output from a Phase 13A background analysis session.
/// Produced by ClaudeService.backgroundAnalysis() — parsed from JSON response.
struct BackgroundWorkResult {
    let checkpointTitle:   String   // short, specific: "Analyzed audio routing deadlock"
    let checkpointSummary: String   // 1–3 sentences: what was found
    let agentContext:      String   // next-session pickup point
    let shouldBlock:       Bool     // true → stop and surface banner without saving checkpoint
    let blockReason:       String?  // human-readable reason shown to user
}

// MARK: - CoordinationTrace

/// Lightweight record of a single assignment decision — kept in a 100-entry ring
/// buffer on AgentCoordinator. Answers "why did this agent pick this project?" without
/// requiring persistence or a second journal. Not written to ProjectEngine.
struct CoordinationTrace {
    let taskId:         UUID
    let projectId:      UUID
    let intent:         WorkIntent
    let assignedAgentId: UUID
    let agentPersona:   AgentPersona
    let timestamp:      Date
}
