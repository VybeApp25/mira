// ScreenCapturePrivacyService.swift
// Keeps Mira out of screenshots, screen recordings and screen sharing.
//
// The preference and the Settings toggle already existed, and so did the
// handling — for exactly one window. MiraIslandWindowManager set its own
// panel's sharingType and nothing else did, so with "Show in screen
// recordings" off the notch vanished from a recording while the dock, the
// cursor companion bubble, the dictation and call HUDs, the agent chips, the
// teaching and guidance overlays and the onboarding demo all stayed in frame.
// A privacy control that covers one of twenty windows is worse than none,
// because it tells you you're hidden when you aren't.
//
// Done here rather than by editing twenty window managers. Windows are created
// all over the app and more get added; a policy applied at each creation site
// is one someone forgets on window twenty-one. This owns the rule in one place
// and enforces it over whatever exists.

import AppKit
import SwiftUI

@MainActor
final class ScreenCapturePrivacyService {

    static let shared = ScreenCapturePrivacyService()

    /// Same key the Settings toggle and the island manager already read.
    /// True means Mira is allowed to appear in capture.
    static var showInCapture: Bool {
        UserDefaults.standard.bool(forKey: MiraIslandWindowManager.showInCaptureKey)
    }

    private var timer: Timer?

    private init() {}

    func start() {
        apply()

        NotificationCenter.default.addObserver(
            forName: .miraShowInCaptureChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { ScreenCapturePrivacyService.shared.apply() }
        }

        // Windows appear long after launch — the agent chip when a run starts,
        // the dictation HUD when you hold the key, an overlay when guidance
        // draws. Rather than requiring each of those to remember the policy,
        // sweep for anything that doesn't match it yet. A handful of windows
        // every few seconds costs nothing, and the check is a field comparison.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { ScreenCapturePrivacyService.shared.apply() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The desired sharing type for every Mira-owned window.
    private var desired: NSWindow.SharingType {
        Self.showInCapture ? .readOnly : .none
    }

    func apply() {
        let want = desired
        for window in NSApp.windows where window.sharingType != want {
            // The Settings window is deliberately included. MacNotch's own copy
            // is that the app "can exclude itself from screenshots, recordings,
            // and screen sharing" — itself, not just its overlay. Someone
            // hiding Mira from a shared screen does not want their account
            // email visible in the one Mira window that looks like a normal app.
            window.sharingType = want
        }
    }
}
