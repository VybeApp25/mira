import AppKit

// Global click monitor that triggers "explain what I clicked" via the cursor companion.
// Mirrors HeyClicky's PointFollowUpConsentPromptView / global click intercept flow.
// Requires Accessibility permission for cross-app click monitoring.

@MainActor
final class PointFollowUpService {
    static let shared = PointFollowUpService()

    private var globalMonitor: Any?
    private var lastFiredAt: Date = .distantPast
    private let cooldown: TimeInterval = 2.0

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "mira_point_follow_up_enabled")
    }

    private init() {}

    func start() {
        guard globalMonitor == nil else { return }

        // NSEvent.addGlobalMonitorForEvents works without AX trust for mouse events
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleGlobalClick(event)
            }
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func handleGlobalClick(_ event: NSEvent) {
        guard isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFiredAt) >= cooldown else { return }
        lastFiredAt = now

        // Convert event location from screen coordinates (y-from-bottom) to CGPoint
        let screenPt = NSEvent.mouseLocation

        NotificationCenter.default.post(
            name: .miraPointFollowUp,
            object: nil,
            userInfo: [
                "screenX": screenPt.x,
                "screenY": screenPt.y,
            ]
        )
    }
}
