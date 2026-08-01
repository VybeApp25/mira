// NotchSnoozeService.swift
// MacNotch's notch Snooze, which it gives a dedicated shortcut pane to.
// Sometimes you want the top of the screen to stop reacting to your cursor for
// a while — presenting, recording, or just working near the menu bar.
//
// Snooze suppresses HOVER-EXPAND only. It deliberately does NOT stop voice,
// agents, Screen Time, or the collapsed strip: this is "stop opening on me",
// not "stop working". Killing background work would make it a mode people are
// afraid to use, and the collapsed pill staying live is how you can tell Mira
// is snoozed rather than broken.

import SwiftUI
import Combine

@MainActor
final class NotchSnoozeService: ObservableObject {

    static let shared = NotchSnoozeService()

    /// True while hover-expand is suppressed.
    @Published private(set) var isSnoozed = false
    /// When the current snooze ends, for the UI to count down against.
    @Published private(set) var until: Date?

    /// Matches the notch-snooze durations MacNotch offers.
    ///
    /// `nonisolated` because it is used as a DEFAULT ARGUMENT below, and default
    /// arguments are evaluated in the caller's context — a main-actor-isolated
    /// constant there is a Swift 6 error, not just a warning.
    nonisolated static let defaultDuration: TimeInterval = 30 * 60

    private var expiry: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .miraToggleSnooze, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.toggle() }
        }
    }

    func toggle(for duration: TimeInterval = NotchSnoozeService.defaultDuration) {
        isSnoozed ? wake() : snooze(for: duration)
    }

    func snooze(for duration: TimeInterval = NotchSnoozeService.defaultDuration) {
        expiry?.cancel()
        isSnoozed = true
        until = Date().addingTimeInterval(duration)

        // Auto-wake. A snooze with no end is an off switch the user will forget
        // they flipped, and then Mira looks broken.
        let work = DispatchWorkItem { [weak self] in self?.wake() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)

        NotificationCenter.default.post(name: .miraSnoozeChanged, object: nil)
    }

    func wake() {
        expiry?.cancel()
        expiry = nil
        isSnoozed = false
        until = nil
        NotificationCenter.default.post(name: .miraSnoozeChanged, object: nil)
    }

    /// Minutes left, for a status label.
    var minutesRemaining: Int {
        guard let until else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow / 60) + 1)
    }
}

extension Notification.Name {
    static let miraSnoozeChanged = Notification.Name("miraSnoozeChanged")
}
