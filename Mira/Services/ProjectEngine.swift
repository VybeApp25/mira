// ProjectEngine.swift
// Phase 1 — Mira Project Engine
//
// The persistent project store and orchestrator.
// Matches MemoryStore pattern: JSON file in ~/Library/Application Support/Mira/
// No new dependencies — pure Swift + Foundation.

import Foundation

// MARK: - Engine

@MainActor
final class ProjectEngine: ObservableObject {

    static let shared = ProjectEngine()

    @Published private(set) var projects: [MiraProject] = []
    /// Non-nil on launch when an in-progress project has resumable work.
    /// Cleared when the user taps Resume or dismisses the banner.
    @Published var pendingContinuation: MiraProject? = nil

    // MARK: - Init

    // MARK: - Evidence snapshot (Phase 14)
    // The latest EvidenceSnapshot is the sole source of delegation authority.
    // Written by BackgroundScheduler via EvidenceEvaluator — never by the UI.
    // Loaded on launch so governance state survives process restarts (Recovery invariant).
    @Published private(set) var latestEvidenceSnapshot: EvidenceSnapshot? = nil

    func recordEvidenceSnapshot(_ snapshot: EvidenceSnapshot) {
        latestEvidenceSnapshot = snapshot
        persistSnapshot()
    }

    private init() {
        load()
        loadSnapshot()
    }

    // MARK: - CRUD

    @discardableResult
    func createProject(name: String,
                       goal: String,
                       criteriaDescriptions: [String] = []) -> MiraProject {
        let criteria = criteriaDescriptions.enumerated().map { i, desc in
            CompletionCriterion(id: UUID(),
                                description: desc,
                                isComplete: false,
                                verifiedAt: nil,
                                verifiedBy: nil,
                                sortOrder: i)
        }
        let project = MiraProject(
            id:                  UUID(),
            name:                name,
            goal:                goal,
            status:              .planning,
            criteria:            criteria,
            checkpoints:         [],
            sessions:            [],
            decisions:           [],
            filesModified:       [],
            lastResumePrompt:    nil,
            activeAgentThreadId: nil,
            activeSessionId:     nil,
            dependencies:        [],
            createdAt:           Date(),
            lastActiveAt:        Date(),
            completedAt:         nil
        )
        projects.insert(project, at: 0)
        persist()
        ProjectEventBus.shared.post(ProjectEvent(
            projectId: project.id,
            type: .projectCreated,
            message: "Project created: \(project.name)"
        ))
        return project
    }

    func update(_ project: MiraProject) {
        guard let idx = indexOf(project.id) else { return }
        projects[idx] = project
        persist()
    }

    func delete(id: UUID) {
        projects.removeAll { $0.id == id }
        persist()
    }

    func archive(id: UUID) {
        guard let idx = indexOf(id) else { return }
        projects[idx].status = .archived
        persist()
    }

    // MARK: - Status Transitions

    func markInProgress(id: UUID, threadId: String? = nil) {
        guard let idx = indexOf(id) else { return }
        projects[idx].status = .inProgress
        projects[idx].activeAgentThreadId = threadId
        projects[idx].lastActiveAt = Date()
        projects[idx].lastResumePrompt = nil   // Will be rebuilt on next checkpoint
        persist()
    }

    func markPaused(id: UUID) {
        guard let idx = indexOf(id) else { return }
        endActiveSession(projectId: id, summary: nil)
        projects[idx].status = .paused
        projects[idx].activeAgentThreadId = nil
        persist()
    }

    func markBlocked(id: UUID, reason: String) {
        guard let idx = indexOf(id) else { return }
        projects[idx].status = .blocked
        projects[idx].activeAgentThreadId = nil
        if let cpIdx = projects[idx].checkpoints.indices.last {
            projects[idx].checkpoints[cpIdx].blockedReason = reason
        }
        persist()
        ProjectEventBus.shared.post(ProjectEvent(
            projectId: id,
            type: .projectBlocked,
            message: reason
        ))
    }

    func markCompleted(id: UUID) {
        guard let idx = indexOf(id) else { return }
        let name = projects[idx].name
        endActiveSession(projectId: id, summary: nil)
        projects[idx].status = .completed
        projects[idx].activeAgentThreadId = nil
        projects[idx].completedAt = Date()
        for ci in projects[idx].criteria.indices {
            if !projects[idx].criteria[ci].isComplete {
                projects[idx].criteria[ci].isComplete = true
                projects[idx].criteria[ci].verifiedAt = Date()
                projects[idx].criteria[ci].verifiedBy = "agent"
            }
        }
        persist()
        ProjectEventBus.shared.post(ProjectEvent(
            projectId: id,
            type: .projectCompleted,
            message: "\(name) completed."
        ))
    }

    // MARK: - Sessions

    @discardableResult
    func startSession(projectId: UUID,
                      persona: AgentPersona = .developer,
                      trigger: SessionTrigger = .userResume) -> ProjectSession? {
        guard let idx = indexOf(projectId) else { return nil }
        // Idempotency guard: if a session started within the last 5 seconds, return it.
        // Prevents duplicate sessions when multiple callers (HUDService, AgentService, tools)
        // converge on the same project simultaneously.
        if let existing = projects[idx].activeSession,
           Date().timeIntervalSince(existing.startedAt) < 5 {
            return existing
        }
        endActiveSession(projectId: projectId, summary: nil)
        let number  = (projects[idx].sessions.last?.number ?? 0) + 1
        let session = ProjectSession(
            id:            UUID(),
            projectId:     projectId,
            number:        number,
            startedAt:     Date(),
            endedAt:       nil,
            persona:       persona,
            trigger:       trigger,
            checkpointIds: [],
            artifactPaths: [],
            summary:       nil
        )
        projects[idx].sessions.append(session)
        projects[idx].activeSessionId = session.id
        markInProgress(id: projectId)
        persist()
        ProjectEventBus.shared.post(ProjectEvent(
            projectId: projectId,
            type: .sessionStarted,
            message: "Session #\(number) · \(persona.displayName)"
        ))
        return session
    }

    func endSession(projectId: UUID, summary: String? = nil) {
        endActiveSession(projectId: projectId, summary: summary)
    }

    private func endActiveSession(projectId: UUID, summary: String?) {
        guard let pIdx = indexOf(projectId),
              let sessionId = projects[pIdx].activeSessionId,
              let sIdx = projects[pIdx].sessions.firstIndex(where: { $0.id == sessionId })
        else { return }
        let number = projects[pIdx].sessions[sIdx].number
        projects[pIdx].sessions[sIdx].endedAt = Date()

        // Quality gate: only write summaries that carry real signal
        if let s = summary, !isWeakSummary(s) {
            projects[pIdx].sessions[sIdx].summary = s
        }

        // Auto-repair: synthesize from checkpoints + artifacts if no quality summary committed
        if projects[pIdx].sessions[sIdx].summary == nil,
           let generated = generateSessionSummary(for: projects[pIdx].sessions[sIdx],
                                                   in: projects[pIdx]),
           !isWeakSummary(generated) {
            projects[pIdx].sessions[sIdx].summary = generated
        }

        projects[pIdx].activeSessionId = nil
        persist()
        let dur = projects[pIdx].sessions[sIdx].duration
        ProjectEventBus.shared.post(ProjectEvent(
            projectId: projectId,
            type: .sessionEnded,
            message: "Session #\(number) ended · \(dur)"
        ))
    }

    /// Repairs a session summary after close — for callers with higher-quality signal
    /// than what was available at endSession time (e.g., a post-hoc Claude synthesis).
    func repairSessionSummary(projectId: UUID, sessionId: UUID, summary: String) {
        guard let pIdx = indexOf(projectId),
              let sIdx = projects[pIdx].sessions.firstIndex(where: { $0.id == sessionId }),
              !isWeakSummary(summary) else { return }
        let number = projects[pIdx].sessions[sIdx].number
        projects[pIdx].sessions[sIdx].summary = summary
        persist()
        ProjectEventBus.shared.post(ProjectEvent(
            projectId: projectId,
            type: .agentUpdate,
            message: "Session #\(number) summary repaired."
        ))
    }

    /// Generates a one-sentence session summary from its checkpoints and artifact names.
    /// Call after endSession when the original summary was nil or weak.
    /// Returns nil if there's nothing to summarize.
    func generateSessionSummary(for session: ProjectSession, in project: MiraProject) -> String? {
        let cps = project.checkpoints
            .filter { session.checkpointIds.contains($0.id) }
            .sorted { $0.number < $1.number }
        let artifacts = session.artifactPaths
            .map { ($0 as NSString).lastPathComponent }
        guard !cps.isEmpty || !artifacts.isEmpty else { return nil }
        var parts: [String] = []
        if !cps.isEmpty {
            parts.append(cps.map(\.title).joined(separator: "; "))
        }
        if !artifacts.isEmpty {
            let fileList = artifacts.prefix(4).joined(separator: ", ")
            parts.append("Files: \(fileList)\(artifacts.count > 4 ? " +\(artifacts.count - 4) more" : "")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Quality Helpers

    private static let weakSummaryPatterns: Set<String> = [
        // Human-driven session generic phrases
        "session complete", "done", "update", "work done", "fixed",
        "progress", "changes made", "session ended", "completed",
        "work completed", "task done", "finished",
        // Phase 13A: background analysis agent generic phrases (common LLM fallbacks)
        "background analysis", "background check-in", "background session",
        "reviewed current state", "analyzed project status", "analyzed project",
        "reviewed project status", "reviewed project", "project review",
        "status review", "reviewed status", "checked in on project",
        "background analysis completed", "continued work", "ongoing work",
        "project analyzed", "state reviewed", "analysis complete",
        "analysis completed", "reviewed code", "code reviewed"
    ]

    func isWeakSummary(_ text: String) -> Bool {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count < 15 { return true }
        return ProjectEngine.weakSummaryPatterns.contains(normalized)
    }

    /// Specificity score (0.0–1.0) for a single text string.
    /// Higher scores indicate named references (file names, identifiers, concrete problems)
    /// rather than generic descriptions.
    private func specificity(of text: String) -> Double {
        guard !isWeakSummary(text) else { return 0.0 }
        var score = 0.2  // baseline for non-weak, non-trivial text

        // File extension reference: names a concrete artifact
        let fileExts = [".swift", ".py", ".js", ".ts", ".json", ".yaml", ".h", ".m", ".c", ".cpp"]
        if fileExts.contains(where: { text.lowercased().contains($0) }) { score += 0.30 }

        // CamelCase or PascalCase identifier: class, function, or type name
        if text.range(of: #"[A-Z][a-z]+[A-Z]|[a-z]+[A-Z][a-z]"#, options: .regularExpression) != nil {
            score += 0.25
        }

        // Concrete problem vocabulary: agent identified something specific
        let concrete = ["identified", "found", "detected", "traced", "caused", "triggered",
                        "blocked", "deadlock", "crash", "leak", "regression", "missing",
                        "incorrect", "race condition", "nil", "overflow", "timeout", "assert"]
        if concrete.contains(where: { text.lowercased().contains($0) }) { score += 0.20 }

        // Length contributes marginally — specificity requires more words
        if text.count > 40 { score += 0.05 }

        return min(score, 1.0)
    }

    /// Rolling specificity score (0.0–1.0) for the last 10 background-triggered checkpoints.
    ///
    /// Measures whether autonomous sessions produce specific, actionable analysis
    /// vs. generic boilerplate. Score bands:
    ///   0.0–0.4  Warning — quality drifting
    ///   0.4–0.7  Healthy
    ///   0.7–1.0  Excellent
    ///
    /// Returns 1.0 (neutral) when no background checkpoints exist yet.
    func backgroundCheckpointSpecificity(for project: MiraProject) -> Double {
        let bgCPIds = Set(project.sessions
            .filter { $0.trigger == .backgroundTimer }
            .flatMap { $0.checkpointIds })

        let recent = project.checkpoints
            .filter { bgCPIds.contains($0.id) }
            .sorted { $0.number > $1.number }
            .prefix(10)

        guard !recent.isEmpty else { return 1.0 }

        let avg = recent.map { specificity(of: $0.title) }.reduce(0.0, +) / Double(recent.count)
        return avg
    }

    // MARK: - Checkpoints

    @discardableResult
    func saveCheckpoint(projectId: UUID,
                        title: String,
                        summary: String,
                        agentContext: String,
                        filesModified: [String] = []) -> ProjectCheckpoint? {
        guard let idx = indexOf(projectId) else { return nil }

        let nextNumber = (projects[idx].checkpoints.last?.number ?? 0) + 1
        let checkpoint = ProjectCheckpoint(
            id:            UUID(),
            number:        nextNumber,
            title:         title,
            summary:       summary,
            agentContext:  agentContext,
            filesModified: filesModified,
            isVerified:    false,
            blockedReason: nil,
            createdAt:     Date()
        )

        projects[idx].checkpoints.append(checkpoint)
        projects[idx].lastActiveAt = Date()
        projects[idx].status = .inProgress

        // Quality gate: warn on generic checkpoint titles
        if isWeakSummary(title) {
            ProjectEventBus.shared.post(ProjectEvent(
                projectId: projectId,
                type: .agentUpdate,
                message: "⚠ Checkpoint #\(nextNumber) title is too generic (\"\(title)\"). Use a specific title like \"Implemented audio routing\"."
            ))
        }

        // Link to active session
        if let sessionId = projects[idx].activeSessionId,
           let sIdx = projects[idx].sessions.firstIndex(where: { $0.id == sessionId }) {
            projects[idx].sessions[sIdx].checkpointIds.append(checkpoint.id)
            let newPaths = Set(filesModified).subtracting(projects[idx].sessions[sIdx].artifactPaths)
            projects[idx].sessions[sIdx].artifactPaths.append(contentsOf: newPaths.sorted())
        }

        ProjectEventBus.shared.post(ProjectEvent(
            projectId: projectId,
            type: .checkpointSaved,
            message: "Checkpoint #\(nextNumber) saved: \(title)"
        ))

        // Accumulate modified files (deduped)
        let allFiles = Set(projects[idx].filesModified).union(filesModified)
        projects[idx].filesModified = Array(allFiles).sorted()

        // Rebuild the resume prompt after every checkpoint
        projects[idx].lastResumePrompt = buildResumePrompt(for: projects[idx])

        persist()
        return checkpoint
    }

    func verifyCheckpoint(projectId: UUID, checkpointId: UUID) {
        guard let pIdx = indexOf(projectId),
              let cIdx = projects[pIdx].checkpoints.firstIndex(where: { $0.id == checkpointId })
        else { return }
        projects[pIdx].checkpoints[cIdx].isVerified = true
        persist()
    }

    // MARK: - Criteria

    func completeCriterion(projectId: UUID, criterionId: UUID, verifiedBy: String = "agent") {
        guard let pIdx = indexOf(projectId),
              let cIdx = projects[pIdx].criteria.firstIndex(where: { $0.id == criterionId })
        else { return }
        projects[pIdx].criteria[cIdx].isComplete = true
        projects[pIdx].criteria[cIdx].verifiedAt = Date()
        projects[pIdx].criteria[cIdx].verifiedBy = verifiedBy
        projects[pIdx].lastActiveAt = Date()

        // Auto-complete project if all criteria are now done, otherwise ensure it's in-progress
        if projects[pIdx].criteria.allSatisfy(\.isComplete) {
            markCompleted(id: projectId)
        } else {
            if projects[pIdx].status == .planning || projects[pIdx].status == .paused {
                projects[pIdx].status = .inProgress
            }
            persist()
        }
    }

    func addCriterion(to projectId: UUID, description: String) {
        guard let idx = indexOf(projectId) else { return }
        let order = projects[idx].criteria.count
        let criterion = CompletionCriterion(id: UUID(),
                                            description: description,
                                            isComplete: false,
                                            verifiedAt: nil,
                                            verifiedBy: nil,
                                            sortOrder: order)
        projects[idx].criteria.append(criterion)
        persist()
    }

    // MARK: - Decisions

    func addDecision(to projectId: UUID, description: String, rationale: String) {
        guard let idx = indexOf(projectId) else { return }
        let decision = ProjectDecision(id: UUID(),
                                       description: description,
                                       rationale: rationale,
                                       createdAt: Date())
        projects[idx].decisions.append(decision)
        persist()
    }

    // MARK: - Resume Prompt

    /// Builds a concise context block the agent uses when resuming a project.
    /// Keeps it under ~600 tokens to leave room for the agent's own reasoning.
    func buildResumePrompt(for project: MiraProject) -> String {
        var lines: [String] = []

        lines.append("Resuming project: \(project.name)")
        lines.append("Goal: \(project.goal)")
        lines.append("")

        // Criteria summary
        let done = project.criteria.filter(\.isComplete).map(\.description)
        let todo = project.criteria.filter { !$0.isComplete }.map(\.description)

        if !done.isEmpty {
            lines.append("Completed:")
            done.forEach { lines.append("  ✓ \($0)") }
        }
        if !todo.isEmpty {
            lines.append("Remaining:")
            todo.forEach { lines.append("  ○ \($0)") }
        }
        lines.append("")

        // Latest checkpoint
        if let cp = project.latestCheckpoint {
            lines.append("Last checkpoint (#\(cp.number)): \(cp.title)")
            lines.append("What was done: \(cp.summary)")
            if !cp.agentContext.isEmpty {
                lines.append("Context: \(cp.agentContext)")
            }
            if let blocked = cp.blockedReason {
                lines.append("⚠️ Was blocked by: \(blocked)")
            }
        }
        lines.append("")

        // Last session summary
        if let session = project.lastCompletedSession {
            lines.append("Last session (#\(session.number), \(session.relativeTime), \(session.persona.displayName)):")
            if let summary = session.summary {
                lines.append("  \(summary)")
            }
            if !session.artifactPaths.isEmpty {
                let paths = session.artifactPaths.suffix(5).joined(separator: ", ")
                lines.append("  Artifacts produced: \(paths)")
            }
            if !session.checkpointIds.isEmpty {
                lines.append("  Checkpoints this session: \(session.checkpointIds.count)")
            }
            lines.append("")
        }

        // Key decisions (last 3)
        let recentDecisions = project.decisions.suffix(3)
        if !recentDecisions.isEmpty {
            lines.append("Key decisions made:")
            recentDecisions.forEach { lines.append("  • \($0.description): \($0.rationale)") }
            lines.append("")
        }

        // Modified files (last 10, most relevant)
        if !project.filesModified.isEmpty {
            let files = Array(project.filesModified.suffix(10))
            lines.append("Files modified: \(files.joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Continue from where you left off. Do not re-do completed work.")

        return lines.joined(separator: "\n")
    }

    // MARK: - Session Intelligence Context

    /// Returns a structured, token-efficient context string for the last `limit` sessions.
    /// Designed for ClaudeService.queryProjectHistory — answers "which session did X?" queries.
    func buildSessionContext(for project: MiraProject, limit: Int = 10) -> String {
        var lines: [String] = []
        lines.append("Project: \(project.name)")
        lines.append("Status: \(project.status.label)")
        lines.append("Total sessions: \(project.sessions.count)")
        lines.append("Total checkpoints: \(project.checkpoints.count)")
        if !project.filesModified.isEmpty {
            lines.append("Files ever modified: \(project.filesModified.count)")
        }
        lines.append("")

        let recent = project.sessions
            .filter { $0.isWorkSession }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)

        guard !recent.isEmpty else {
            lines.append("No sessions recorded yet.")
            return lines.joined(separator: "\n")
        }

        lines.append("Sessions (most recent first):")
        for session in recent {
            lines.append("")
            lines.append("Session #\(session.number) — \(session.persona.displayName)")
            lines.append("  When: \(session.relativeTime)  Duration: \(session.duration)")
            if let summary = session.summary {
                lines.append("  Summary: \(summary)")
            }
            if !session.artifactPaths.isEmpty {
                let names = session.artifactPaths
                    .map { ($0 as NSString).lastPathComponent }
                    .joined(separator: ", ")
                lines.append("  Artifacts: \(names)")
            }
            let cps = project.checkpoints
                .filter { session.checkpointIds.contains($0.id) }
                .sorted { $0.number < $1.number }
            if !cps.isEmpty {
                let cpStr = cps.map { "#\($0.number): \($0.title)" }.joined(separator: "; ")
                lines.append("  Checkpoints: \(cpStr)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Queries

    var activeProjects: [MiraProject] {
        projects.filter { $0.status == .inProgress || $0.status == .paused || $0.status == .blocked }
    }

    /// True when any project has a user-initiated session currently active.
    /// Use this for Phase 11 scheduler guards — NOT HUDService.isActive.
    /// HUD state ≠ user intent; a session can be active with the HUD collapsed.
    var hasActiveUserSession: Bool {
        projects.contains { project in
            guard let session = project.activeSession else { return false }
            return session.trigger == .userResume || session.trigger == .userCommand
        }
    }

    var completedProjects: [MiraProject] {
        projects.filter { $0.status == .completed }
    }

    /// Projects that were in-progress when the app last quit — candidates for auto-resume.
    func interruptedProjects() -> [MiraProject] {
        projects.filter { $0.status == .inProgress }
    }

    func project(id: UUID) -> MiraProject? {
        projects.first { $0.id == id }
    }

    // MARK: - Dependencies (Phase 16)

    @discardableResult
    func addDependency(from projectId: UUID, to dependsOnId: UUID,
                       kind: DependencyKind, note: String? = nil) -> Bool {
        guard projectId != dependsOnId,
              let idx = indexOf(projectId),
              project(id: dependsOnId) != nil else { return false }
        guard !wouldCreateCycle(from: projectId, to: dependsOnId) else { return false }
        let dep = ProjectDependency(id: UUID(), toProjectId: dependsOnId,
                                    kind: kind, note: note, createdAt: Date())
        projects[idx].dependencies.append(dep)
        persist()
        return true
    }

    func removeDependency(id depId: UUID, from projectId: UUID) {
        guard let idx = indexOf(projectId) else { return }
        projects[idx].dependencies.removeAll { $0.id == depId }
        persist()
    }

    func upstreamProjects(for projectId: UUID) -> [(dep: ProjectDependency, project: MiraProject)] {
        guard let proj = project(id: projectId) else { return [] }
        return proj.dependencies.compactMap { dep in
            guard let p = project(id: dep.toProjectId) else { return nil }
            return (dep, p)
        }
    }

    func downstreamProjects(for projectId: UUID) -> [(dep: ProjectDependency, project: MiraProject)] {
        projects.compactMap { p in
            guard let dep = p.dependencies.first(where: { $0.toProjectId == projectId }) else { return nil }
            return (dep, p)
        }
    }

    func isBlockedByDependency(_ projectId: UUID) -> Bool {
        guard let proj = project(id: projectId) else { return false }
        return proj.dependencies
            .filter { $0.kind == .blocks }
            .contains { dep in
                project(id: dep.toProjectId)?.status != .completed
            }
    }

    private func wouldCreateCycle(from startId: UUID, to targetId: UUID) -> Bool {
        var visited = Set<UUID>()
        var queue = [targetId]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == startId { return true }
            if visited.contains(current) { continue }
            visited.insert(current)
            if let proj = project(id: current) {
                queue.append(contentsOf: proj.dependencies.map { $0.toProjectId })
            }
        }
        return false
    }

    // MARK: - File Tracking (called by agent tools)

    func trackFilesModified(_ paths: [String], for projectId: UUID) {
        guard let idx = indexOf(projectId) else { return }
        let updated = Set(projects[idx].filesModified).union(paths)
        projects[idx].filesModified = Array(updated).sorted()
        projects[idx].lastActiveAt = Date()
        persist()
    }

    // MARK: - Private Helpers

    private func indexOf(_ id: UUID) -> Int? {
        projects.firstIndex { $0.id == id }
    }

    // MARK: - Persistence

    private func load() {
        guard let data    = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([MiraProject].self, from: data)
        else { return }
        projects = decoded
        recoverOrphanedSessions()
        // Surface the most recently active project that has resumable work
        pendingContinuation = projects
            .filter {
                ($0.status == .inProgress || $0.status == .paused)
                && (!$0.checkpoints.isEmpty || !$0.sessions.isEmpty)
            }
            .max(by: { $0.lastActiveAt < $1.lastActiveAt })
    }

    func dismissContinuation() {
        pendingContinuation = nil
    }

    /// On launch, close any sessions that never received an endedAt — caused by force-quit or crash.
    /// Sessions active for > 5 minutes with no endedAt are treated as orphaned and stamped closed.
    private func recoverOrphanedSessions() {
        let cutoff = Date().addingTimeInterval(-300)   // 5 minutes
        var changed = false
        for pIdx in projects.indices {
            guard projects[pIdx].activeSessionId != nil else { continue }
            for sIdx in projects[pIdx].sessions.indices {
                guard projects[pIdx].sessions[sIdx].endedAt == nil,
                      projects[pIdx].sessions[sIdx].startedAt < cutoff else { continue }
                projects[pIdx].sessions[sIdx].endedAt = projects[pIdx].sessions[sIdx].startedAt.addingTimeInterval(300)
                projects[pIdx].sessions[sIdx].summary = projects[pIdx].sessions[sIdx].summary ?? "Session interrupted — recovered on restart."
                changed = true
            }
            // Clear the activeSessionId if the session is now closed
            if let id = projects[pIdx].activeSessionId,
               projects[pIdx].sessions.first(where: { $0.id == id })?.endedAt != nil {
                projects[pIdx].activeSessionId = nil
                changed = true
            }
        }
        if changed { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func loadSnapshot() {
        guard let data    = try? Data(contentsOf: snapshotURL),
              let decoded = try? JSONDecoder().decode(EvidenceSnapshot.self, from: data)
        else { return }
        latestEvidenceSnapshot = decoded
    }

    private func persistSnapshot() {
        guard let snapshot = latestEvidenceSnapshot,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private var snapshotURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("evidence_snapshot.json")
    }

    private var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }
}
