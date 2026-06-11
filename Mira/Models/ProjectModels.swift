// ProjectModels.swift
// Phase 1 — Mira Project Engine
//
// Core data model for persistent, checkpoint-aware projects.
// All types are Codable so they serialize to the JSON store.
// No new dependencies — matches existing MemoryStore persistence pattern.

import Foundation

// MARK: - AgentPersona

enum AgentPersona: String, Codable, CaseIterable {
    case developer  = "developer"
    case tester     = "tester"
    case researcher = "researcher"
    case writer     = "writer"

    var displayName: String {
        switch self {
        case .developer:  return "Mira Developer"
        case .tester:     return "Mira Tester"
        case .researcher: return "Mira Researcher"
        case .writer:     return "Mira Writer"
        }
    }

    var icon: String {
        switch self {
        case .developer:  return "hammer.fill"
        case .tester:     return "checkmark.shield.fill"
        case .researcher: return "magnifyingglass"
        case .writer:     return "pencil"
        }
    }
}

// MARK: - SessionTrigger

/// Records how a session was initiated — the "why" behind the "what".
/// Evidence-based trust (Phase 11+) requires provenance, not just outcome.
enum SessionTrigger: String, Codable {
    case userResume      = "user_resume"      // User confirmed continuation banner
    case userCommand     = "user_command"     // Explicit voice/text command
    case backgroundTimer = "background_timer" // Scheduled execution (Phase 11)
    case externalHook    = "external_hook"    // Webhook / file watch / CI (Phase 12)
    case agentInitiated  = "agent_initiated"  // Fully autonomous (Phase 13)

    var displayName: String {
        switch self {
        case .userResume:      return "User resumed"
        case .userCommand:     return "User command"
        case .backgroundTimer: return "Background scheduler"
        case .externalHook:    return "External trigger"
        case .agentInitiated:  return "Agent initiated"
        }
    }
}

// MARK: - ProjectSession

struct ProjectSession: Identifiable, Codable {
    let id:            UUID
    let projectId:     UUID
    let number:        Int          // 1-based, sequential within project
    var startedAt:     Date
    var endedAt:       Date?
    var persona:       AgentPersona
    var trigger:       SessionTrigger  // Why this session was initiated
    var checkpointIds: [UUID]       // References to ProjectCheckpoint.id (not owned)
    var artifactPaths: [String]     // Paths produced this session
    var summary:       String?      // Set at session end

    var isActive: Bool { endedAt == nil }

    /// True when the session represents real work (has checkpoints, or was explicitly user-initiated).
    /// Background pings (backgroundTimer + no checkpoints) return false.
    var isWorkSession: Bool {
        !checkpointIds.isEmpty
            || trigger == .userResume
            || trigger == .userCommand
    }

    var duration: String {
        let end  = endedAt ?? Date()
        let diff = end.timeIntervalSince(startedAt)
        if diff < 60    { return "< 1 min" }
        if diff < 3_600 { return "\(Int(diff / 60))m" }
        let h = Int(diff / 3_600)
        let m = Int(diff.truncatingRemainder(dividingBy: 3_600) / 60)
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    var relativeTime: String {
        let ref  = endedAt ?? startedAt
        let diff = Date().timeIntervalSince(ref)
        if diff < 60     { return "just now" }
        if diff < 3_600  { return "\(Int(diff / 60))m ago" }
        if diff < 86_400 { return "\(Int(diff / 3_600))h ago" }
        return "\(Int(diff / 86_400))d ago"
    }
}

// MARK: - Project

struct MiraProject: Identifiable, Codable {
    let id:           UUID
    var name:         String                    // e.g. "Vybe iOS App"
    var goal:         String                    // e.g. "A working iOS app with voice and Dynamic Island"
    var status:       ProjectStatus
    var criteria:     [CompletionCriterion]
    var checkpoints:  [ProjectCheckpoint]
    var sessions:     [ProjectSession]
    var decisions:    [ProjectDecision]
    var filesModified: [String]                 // Tracked paths, deduped
    var lastResumePrompt: String?               // Auto-generated context for resuming
    var activeAgentThreadId: String?            // Non-nil while an agent is running
    var activeSessionId: UUID?                  // Non-nil during an active work session
    var dependencies: [ProjectDependency]       // Phase 16: outgoing dependency edges

    let createdAt:    Date
    var lastActiveAt: Date
    var completedAt:  Date?

    // MARK: Computed

    var completedCriteriaCount: Int {
        criteria.filter(\.isComplete).count
    }

    var progressPercent: Int {
        guard !criteria.isEmpty else { return 0 }
        return Int((Double(completedCriteriaCount) / Double(criteria.count)) * 100)
    }

    var isStalled: Bool {
        status == .inProgress && lastActiveAt < Date().addingTimeInterval(-3600)
    }

    var latestCheckpoint: ProjectCheckpoint? {
        checkpoints.max(by: { $0.number < $1.number })
    }

    var nextIncompleteCriterion: CompletionCriterion? {
        criteria.first(where: { !$0.isComplete })
    }

    var relativeTime: String {
        let diff = Date().timeIntervalSince(lastActiveAt)
        if diff < 60        { return "just now" }
        if diff < 3_600     { return "\(Int(diff / 60))m ago" }
        if diff < 86_400    { return "\(Int(diff / 3_600))h ago" }
        return "\(Int(diff / 86_400))d ago"
    }

    var activeSession: ProjectSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var lastCompletedSession: ProjectSession? {
        sessions.filter { !$0.isActive && $0.isWorkSession }
            .max(by: { $0.startedAt < $1.startedAt })
    }
}

// MARK: - ProjectStatus

enum ProjectStatus: String, Codable, CaseIterable {
    case planning   = "planning"    // Created, no agent run yet
    case inProgress = "in_progress" // Agent has worked on it
    case paused     = "paused"      // Intentionally paused by user
    case blocked    = "blocked"     // Needs user input or missing resource
    case completed  = "completed"   // All criteria met
    case archived   = "archived"    // Hidden from active list

    var label: String {
        switch self {
        case .planning:   return "Planning"
        case .inProgress: return "In Progress"
        case .paused:     return "Paused"
        case .blocked:    return "Blocked"
        case .completed:  return "Completed"
        case .archived:   return "Archived"
        }
    }

    var icon: String {
        switch self {
        case .planning:   return "doc.badge.plus"
        case .inProgress: return "bolt.fill"
        case .paused:     return "pause.circle.fill"
        case .blocked:    return "exclamationmark.triangle.fill"
        case .completed:  return "checkmark.circle.fill"
        case .archived:   return "archivebox.fill"
        }
    }
}

// MARK: - DependencyKind

enum DependencyKind: String, Codable, CaseIterable {
    case blocks   = "blocks"
    case requires = "requires"
    case informs  = "informs"
    case succeeds = "succeeds"

    var label: String {
        switch self {
        case .blocks:   return "Blocks"
        case .requires: return "Requires"
        case .informs:  return "Informs"
        case .succeeds: return "Succeeds"
        }
    }

    var icon: String {
        switch self {
        case .blocks:   return "lock.fill"
        case .requires: return "link"
        case .informs:  return "arrow.right"
        case .succeeds: return "arrow.right.circle"
        }
    }
}

// MARK: - ProjectDependency

struct ProjectDependency: Identifiable, Codable {
    let id:          UUID
    let toProjectId: UUID
    let kind:        DependencyKind
    let note:        String?
    let createdAt:   Date
}

// MARK: - CompletionCriterion

struct CompletionCriterion: Identifiable, Codable {
    let id:          UUID
    var description: String      // "App builds cleanly on device"
    var isComplete:  Bool
    var verifiedAt:  Date?
    var verifiedBy:  String?     // "agent" | "user"
    var sortOrder:   Int
}

// MARK: - ProjectCheckpoint

struct ProjectCheckpoint: Identifiable, Codable {
    let id:           UUID
    let number:       Int        // Sequential, 1-based
    var title:        String     // "SwiftUI views complete"
    var summary:      String     // What the agent did since the last checkpoint
    var agentContext: String     // Serialized context for resume (files, state, next steps)
    var filesModified: [String]  // Paths changed since previous checkpoint
    var isVerified:   Bool       // Agent confirmed checkpoint output
    var blockedReason: String?   // Why this checkpoint didn't finish, if blocked
    let createdAt:    Date

    var relativeTime: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60        { return "just now" }
        if diff < 3_600     { return "\(Int(diff / 60))m ago" }
        if diff < 86_400    { return "\(Int(diff / 3_600))h ago" }
        return "\(Int(diff / 86_400))d ago"
    }
}

// MARK: - ProjectDecision

struct ProjectDecision: Identifiable, Codable {
    let id:          UUID
    var description: String     // "Chose SwiftData over CoreData"
    var rationale:   String     // "Simpler API for this scope, no migration needed"
    let createdAt:   Date
}

// MARK: - AgentResult (task completion output, parsed from agent response)

struct AgentResult: Codable {
    var summary:      String              // 1–2 sentences, plain text, no markdown
    var doneTitle:    String              // Noun form: "Vybe Auth System"
    var artifacts:    [AgentArtifact]
    var nextActions:  [ProjectNextAction]
    var checkpointId: UUID?               // Checkpoint saved during this run
    var projectId:    UUID?               // Project this belongs to, if any
}

// MARK: - AgentArtifact

struct AgentArtifact: Identifiable, Codable {
    let id:          UUID
    var filePath:    String?              // Absolute local path
    var webURL:      String?              // https://... URL
    var displayName: String
    var kind:        ArtifactKind

    enum ArtifactKind: String, Codable {
        case file, url, report, code, document
    }
}

// MARK: - ProjectNextAction (tappable chip after task completion)

struct ProjectNextAction: Identifiable, Codable {
    let id:    UUID
    var label: String    // "Open the file" — shown on chip, max 35 chars
    var prompt: String   // Exact text sent as next user message when tapped
    var icon:  String    // SF Symbol name
}

// MARK: - CompletionSummary (computed from a completed MiraProject)

struct CompletionSummary {
    let completedAt:       Date
    let sessionCount:      Int
    let checkpointCount:   Int
    let artifactCount:     Int
    let totalTimeInvested: TimeInterval
    let personaBreakdown:  [(persona: AgentPersona, sessions: Int)]

    init(project: MiraProject) {
        completedAt     = project.completedAt ?? Date()
        sessionCount    = project.sessions.count
        checkpointCount = project.checkpoints.count
        artifactCount   = project.filesModified.count
        totalTimeInvested = project.sessions
            .filter { !$0.isActive }
            .reduce(0) { total, s in
                total + (s.endedAt ?? Date()).timeIntervalSince(s.startedAt)
            }
        let grouped = Dictionary(grouping: project.sessions, by: \.persona)
        personaBreakdown = grouped
            .map { (persona: $0.key, sessions: $0.value.count) }
            .sorted { $0.sessions > $1.sessions }
    }

    var formattedTimeInvested: String {
        let total = Int(totalTimeInvested)
        let h     = total / 3_600
        let m     = (total % 3_600) / 60
        if h == 0 && m == 0 { return "< 1m" }
        if h == 0            { return "\(m)m" }
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}

extension MiraProject {
    var completionSummary: CompletionSummary? {
        guard status == .completed else { return nil }
        return CompletionSummary(project: self)
    }
}

// MARK: - ProjectSession Codable (migration-safe: trigger defaults to .userResume for existing sessions)

extension ProjectSession {
    private enum CodingKeys: String, CodingKey {
        case id, projectId, number, startedAt, endedAt, persona, trigger
        case checkpointIds, artifactPaths, summary
    }

    init(from decoder: Decoder) throws {
        let c          = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,          forKey: .id)
        projectId      = try c.decode(UUID.self,          forKey: .projectId)
        number         = try c.decode(Int.self,           forKey: .number)
        startedAt      = try c.decode(Date.self,          forKey: .startedAt)
        endedAt        = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        persona        = try c.decode(AgentPersona.self,  forKey: .persona)
        trigger        = try c.decodeIfPresent(SessionTrigger.self, forKey: .trigger) ?? .userResume
        checkpointIds  = try c.decode([UUID].self,        forKey: .checkpointIds)
        artifactPaths  = try c.decode([String].self,      forKey: .artifactPaths)
        summary        = try c.decodeIfPresent(String.self, forKey: .summary)
    }
}

// MARK: - MiraProject Codable (migration-safe: decodeIfPresent for fields added after v1)

extension MiraProject {
    private enum CodingKeys: String, CodingKey {
        case id, name, goal, status, criteria, checkpoints, sessions, decisions
        case filesModified, lastResumePrompt, activeAgentThreadId, activeSessionId
        case createdAt, lastActiveAt, completedAt, dependencies
    }

    init(from decoder: Decoder) throws {
        let c               = try decoder.container(keyedBy: CodingKeys.self)
        id                  = try c.decode(UUID.self,                    forKey: .id)
        name                = try c.decode(String.self,                  forKey: .name)
        goal                = try c.decode(String.self,                  forKey: .goal)
        status              = try c.decode(ProjectStatus.self,           forKey: .status)
        criteria            = try c.decode([CompletionCriterion].self,   forKey: .criteria)
        checkpoints         = try c.decode([ProjectCheckpoint].self,     forKey: .checkpoints)
        sessions            = try c.decodeIfPresent([ProjectSession].self, forKey: .sessions) ?? []
        decisions           = try c.decode([ProjectDecision].self,       forKey: .decisions)
        filesModified       = try c.decode([String].self,                forKey: .filesModified)
        lastResumePrompt    = try c.decodeIfPresent(String.self,         forKey: .lastResumePrompt)
        activeAgentThreadId = try c.decodeIfPresent(String.self,         forKey: .activeAgentThreadId)
        activeSessionId     = try c.decodeIfPresent(UUID.self,           forKey: .activeSessionId)
        dependencies        = (try? c.decode([ProjectDependency].self,   forKey: .dependencies)) ?? []
        createdAt           = try c.decode(Date.self,                    forKey: .createdAt)
        lastActiveAt        = try c.decode(Date.self,                    forKey: .lastActiveAt)
        completedAt         = try c.decodeIfPresent(Date.self,           forKey: .completedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,              forKey: .id)
        try c.encode(name,            forKey: .name)
        try c.encode(goal,            forKey: .goal)
        try c.encode(status,          forKey: .status)
        try c.encode(criteria,        forKey: .criteria)
        try c.encode(checkpoints,     forKey: .checkpoints)
        try c.encode(sessions,        forKey: .sessions)
        try c.encode(decisions,       forKey: .decisions)
        try c.encode(filesModified,   forKey: .filesModified)
        try c.encodeIfPresent(lastResumePrompt,    forKey: .lastResumePrompt)
        try c.encodeIfPresent(activeAgentThreadId, forKey: .activeAgentThreadId)
        try c.encodeIfPresent(activeSessionId,     forKey: .activeSessionId)
        try c.encode(dependencies,    forKey: .dependencies)
        try c.encode(createdAt,       forKey: .createdAt)
        try c.encode(lastActiveAt,    forKey: .lastActiveAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}
