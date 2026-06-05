// HUDService.swift
// Phase 2 — Radio-dispatch HUD stream for the Mira notch island.
//
// Receives ProjectEvents from ProjectEventBus and translates them into
// concise, active-voice HUD messages. Also accepts direct postUpdate()
// calls from the agent backend for live in-task commentary.
//
// Design contract (mirrors HeyClicky's radio-dispatch rule):
// • One sentence, active voice, present tense
// • No "I am", "I will", "We" — always the action itself
//   ✓ "Analyzing VoiceManager.swift."
//   ✗ "I am analyzing VoiceManager.swift."
// • Prefer milestone over step-by-step chatter

import Foundation

@MainActor
final class HUDService: ObservableObject {

    static let shared = HUDService()

    // MARK: - Published state

    @Published private(set) var isActive:       Bool       = false
    @Published private(set) var currentMessage: String     = ""
    @Published private(set) var updates:        [HUDUpdate] = []   // Last 30 messages
    @Published private(set) var currentCategory: HUDCategory = .starting
    @Published private(set) var activeProjectName: String?  = nil   // Shown in notch nav bar

    // MARK: - Private

    private var eventToken: NSObjectProtocol?

    // MARK: - Init

    private init() {
        eventToken = ProjectEventBus.shared.addObserver { [weak self] event in
            self?.handle(event)
        }
    }

    deinit {
        if let token = eventToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Public API

    /// Called by the agent backend to post a live radio-dispatch update.
    /// `message` must already conform to the style contract above.
    func postUpdate(_ message: String, category: HUDCategory = .working) {
        let update = HUDUpdate(message: message, category: category)
        currentMessage = message
        currentCategory = category
        updates.append(update)
        if updates.count > 30 { updates.removeFirst() }
    }

    /// Marks the session as started (called when agent task begins).
    func startSession(projectId: UUID? = nil,
                      projectName: String? = nil,
                      taskHint: String? = nil,
                      trigger: SessionTrigger = .userCommand) {
        isActive = true
        updates = []
        activeProjectName = projectName
        postUpdate("Starting up.", category: .starting)

        // Phase 9: wire into ProjectEngine session lifecycle
        if let pid = projectId {
            let persona = inferPersona(from: taskHint ?? projectName ?? "")
            ProjectEngine.shared.startSession(projectId: pid, persona: persona, trigger: trigger)
        }

        if let name = projectName {
            ProjectEventBus.shared.post(ProjectEvent(
                projectId: projectId,
                type: .agentStarted,
                message: "Agent started: \(name)"
            ))
        }
    }

    /// Marks the session as complete (called when AgentResult is received).
    func endSession(result: AgentResult) {
        postUpdate("Done.", category: .completing)
        isActive = false

        if let pid = result.projectId {
            let summary = result.summary.isEmpty ? nil : result.summary
            ProjectEngine.shared.endSession(projectId: pid, summary: summary)
            ProjectEventBus.shared.post(ProjectEvent(
                projectId: pid,
                type: .agentFinished,
                message: result.doneTitle
            ))
        }
    }

    /// Marks the session as blocked — agent stopped and needs user input.
    func blockSession(reason: String) {
        postUpdate(reason, category: .blocked)
        isActive = false
    }

    // MARK: - Persona Inference

    /// Infers the agent persona from the task description / project name.
    /// Keyword-based — covers the common cases without needing an extra Claude call.
    private func inferPersona(from hint: String) -> AgentPersona {
        let lower = hint.lowercased()
        // Level 1 — domain hard overrides: work type, not role signal.
        // These win regardless of other keywords (investigating a bug = tester, not researcher).
        let bugDomain = ["bug", "crash", "regression", "broken", "not working", "exception", "error"]
        if bugDomain.contains(where: { lower.contains($0) }) { return .tester }
        // Level 2 — role signals (priority order)
        let testerSignals   = ["test", "verify", "validat", "qa", "debug"]
        let researchSignals = ["research", "analyz", "investigat", "explor", "review", "audit", "survey"]
        let writerSignals   = ["write", "document", "draft", "readme", "spec", "proposal", "report"]
        if testerSignals.contains(where:   { lower.contains($0) }) { return .tester }
        if researchSignals.contains(where: { lower.contains($0) }) { return .researcher }
        if writerSignals.contains(where:   { lower.contains($0) }) { return .writer }
        return .developer
    }

    // MARK: - Event handler

    private func handle(_ event: ProjectEvent) {
        switch event.type {
        case .agentStarted:
            isActive = true
            if updates.isEmpty { postUpdate("Starting up.", category: .starting) }

        case .checkpointSaved:
            postUpdate(event.message, category: .checkpointing)

        case .criterionCompleted:
            postUpdate(event.message, category: .completing)

        case .projectCompleted:
            postUpdate(event.message, category: .completing)

        case .agentUpdate:
            // Direct live update from agent backend
            postUpdate(event.message)

        case .agentFinished:
            isActive = false

        case .projectBlocked:
            blockSession(reason: event.message)

        default:
            break
        }
    }
}
