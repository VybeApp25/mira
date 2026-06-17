import Foundation
import AVFoundation
import UserNotifications

// MARK: - Task completion announcer
//
// The autonomous-control UX (see project_mira_autonomy_direction): a task runs
// SILENTLY in the background via AXActuationService (no cursor theft, app stays
// where it is) and Mira tells the user it's done two ways at once —
//   1. a system notification (so there's a persistent, glanceable record), and
//   2. spoken voice — a BRIEF of what was done (not just "done"), in the user's
//      selected Mira voice via the live realtime session. The full detail is
//      seeded into the conversation so a follow-up ("what did you do?") can be
//      answered. Falls back to Miso, then the system voice, so it's never silent.
//
// This is intentionally decoupled from how the task ran: any background
// actuation (AX or cursor fallback) calls announce(...) on completion.

@MainActor
final class TaskAnnouncer {
    static let shared = TaskAnnouncer()

    /// System-voice fallback used only when no live session and Miso isn't
    /// configured, so a completion is never silent.
    private let fallbackSynth = AVSpeechSynthesizer()

    private init() {}

    /// The most recent completed task, kept so other surfaces (and the user
    /// asking "what did you just do?") can reference the full detail.
    struct Summary { let task: String; let success: Bool; let detail: String?; let date: Date }
    private(set) var lastSummary: Summary?

    /// Announce the outcome of a background task: posts a notification and speaks
    /// a brief of what was done.
    /// - Parameters:
    ///   - task: what was attempted, phrased as an action ("send the email").
    ///   - success: whether the task completed.
    ///   - detail: richer outcome (error, mechanism, result) — shown in the
    ///     notification and seeded as voice follow-up context.
    func announce(task: String, success: Bool, detail: String? = nil) {
        let title = success ? "Mira finished" : "Mira couldn't finish"
        // A brief that says WHAT was done, not just "done".
        let brief = success ? "Done — \(task)." : "I couldn't \(task)."
        // Full context for a spoken follow-up.
        let context = (success ? "I just finished: \(task)."
                               : "I tried to \(task) but it didn't complete.")
                    + (detail.map { " Details: \($0)" } ?? "")

        lastSummary = Summary(task: task, success: success, detail: detail, date: Date())
        postNotification(title: title, body: detail ?? task)
        speak(brief: brief, context: context)
    }

    /// Run a background actuation closure, then announce the outcome. The closure
    /// is the actual AX/cursor work; this wrapper guarantees the user is always
    /// told the result — even on a thrown error — exactly once.
    func run(task: String, _ work: @MainActor () throws -> Void) {
        do {
            try work()
            announce(task: task, success: true)
        } catch {
            announce(task: task, success: false, detail: "\(error)")
        }
    }

    // MARK: - Speak (selected Mira voice → Miso → system voice)

    private func speak(brief: String, context: String) {
        // 1) Preferred: the user's selected Mira voice, spoken through the live
        //    realtime session — which also seeds `context` for follow-ups.
        if RealtimeVoiceService.shared.speakAnnouncement(brief: brief, context: context) {
            return
        }
        // 2) Miso TTS if configured.
        if MisoTTSService.shared.isConfigured {
            MisoTTSService.shared.speak(brief)
            return
        }
        // 3) System voice — never silent.
        fallbackSynth.stopSpeaking(at: .immediate)
        fallbackSynth.speak(AVSpeechUtterance(string: brief))
    }

    // MARK: - Notify

    private func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        // Authorization is requested at launch (BackgroundScheduler); request
        // defensively in case this fires first. add() no-ops if denied.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        center.add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { _ in }
    }
}
