// ProjectEvent.swift
// Phase 2 — Shared event stream for HUD, timeline, notifications, and future multi-agent.
//
// Every meaningful state change in the Project Engine emits a ProjectEvent.
// Consumers (HUDService, future timeline, future notifications) subscribe
// independently without knowing about each other.

import Foundation

// MARK: - Event type

enum ProjectEventType: String, Codable {
    case projectCreated      = "project_created"
    case projectCompleted    = "project_completed"
    case projectPaused       = "project_paused"
    case projectBlocked      = "project_blocked"
    case checkpointSaved     = "checkpoint_saved"
    case criterionCompleted  = "criterion_completed"
    case agentStarted        = "agent_started"
    case agentFinished       = "agent_finished"
    case agentUpdate         = "agent_update"        // Live radio-dispatch HUD message
    case sessionStarted      = "session_started"
    case sessionEnded        = "session_ended"
    case decisionRecorded    = "decision_recorded"
    case filesModified       = "files_modified"
}

// MARK: - Event

struct ProjectEvent {
    let id:        UUID
    let timestamp: Date
    let projectId: UUID?        // nil for app-level events
    let type:      ProjectEventType
    let message:   String       // Human-readable one-liner, used directly in HUD

    init(projectId: UUID? = nil, type: ProjectEventType, message: String) {
        self.id        = UUID()
        self.timestamp = Date()
        self.projectId = projectId
        self.type      = type
        self.message   = message
    }
}

// MARK: - Event bus

/// Lightweight publisher. ProjectEngine posts; HUDService, Timeline, etc. subscribe.
/// Uses NotificationCenter under the hood so subscribers don't need a direct reference.
@MainActor
final class ProjectEventBus {

    static let shared = ProjectEventBus()

    private let notificationName = Notification.Name("MiraProjectEvent")

    private init() {}

    func post(_ event: ProjectEvent) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: ["event": event]
        )
    }

    /// Adds an observer. Returns the observer token — call `removeObserver(_:)` on deinit.
    @discardableResult
    func addObserver(handler: @escaping @MainActor (ProjectEvent) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            guard let event = notification.userInfo?["event"] as? ProjectEvent else { return }
            Task { @MainActor in handler(event) }
        }
    }

    func removeObserver(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }
}
