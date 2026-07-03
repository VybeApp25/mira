import SwiftUI
import Combine

// MARK: - AgentTaskManager
//
// The single source of truth for *ephemeral* live agent activities — the
// bottom-right floating chips that show "what is Mira doing right now?" while a
// computer-use / autonomy run (or, later, a voice command or tool call) is in
// flight, then fade out.
//
// This is intentionally a thin, in-memory lane that renders through the EXISTING
// AgentHUDWindowManager NSPanel (see AgentHUDColumnView) — it does NOT spin up an
// agent runner and does NOT persist. It sits alongside AgentJobStore (heavy,
// persisted website/research jobs); the two chip families share one panel and
// one visual language.
//
// Philosophy (Clicky-style): one chip per task, updated in place through
// perception → reasoning → action phases. Do not create a chip per function
// call — that's chip spam. Only surface work the user would wonder about.

@MainActor
final class AgentTaskManager: ObservableObject {
    static let shared = AgentTaskManager()
    private init() {}

    /// Live activities, newest first. Rendered at the top of the bottom-right stack.
    @Published private(set) var activeTasks: [AgentActivity] = []

    /// How long a finished chip lingers before it fades out (background = brief).
    private let dismissDelay: TimeInterval = 1.8

    // MARK: - Lifecycle

    /// Begin tracking a new activity. Returns its id so the caller can drive it.
    @discardableResult
    func start(title: String, subtitle: String = "Starting…",
               status: AgentActivityStatus = .running) -> UUID {
        var activity = AgentActivity(title: title, subtitle: subtitle, status: status)
        activity.progress = 0.06
        activeTasks.insert(activity, at: 0)
        return activity.id
    }

    /// Update an in-flight activity. Any field left nil is untouched.
    func update(_ id: UUID,
                status: AgentActivityStatus? = nil,
                subtitle: String? = nil,
                progress: Double? = nil) {
        guard let idx = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        if let status   { activeTasks[idx].status   = status }
        if let subtitle { activeTasks[idx].subtitle = subtitle }
        if let progress { activeTasks[idx].progress = min(max(progress, 0), 1) }
    }

    /// Nudge the progress bar forward for indeterminate work so the chip feels
    /// alive without ever "completing" until the task truly finishes. Caps at 0.9.
    func creepProgress(_ id: UUID, toward ceiling: Double = 0.9, by step: Double = 0.04) {
        guard let idx = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        let next = activeTasks[idx].progress + step * (ceiling - activeTasks[idx].progress)
        activeTasks[idx].progress = min(next, ceiling)
    }

    /// Mark the activity done (or failed) and schedule its fade-out.
    func finish(_ id: UUID, success: Bool, summary: String? = nil) {
        guard let idx = activeTasks.firstIndex(where: { $0.id == id }) else { return }
        activeTasks[idx].status   = success ? .completed : .failed
        activeTasks[idx].subtitle = summary ?? (success ? "Done" : "Failed")
        activeTasks[idx].progress = 1.0
        scheduleDismiss(id)
    }

    /// Remove immediately (no grace period).
    func remove(_ id: UUID) {
        activeTasks.removeAll { $0.id == id }
    }

    // MARK: - Private

    private func scheduleDismiss(_ id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.dismissDelay ?? 1.8) * 1_000_000_000))
            self?.remove(id)
        }
    }
}
