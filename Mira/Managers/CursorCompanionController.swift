// CursorCompanionController.swift
// Owns the dock/undock state of Mira's cursor companion bubble (the floating
// bubble that follows the pointer and shows voice state). Home Tab Add-ons spec §2.
//
// Model:
//   • Undocked (default) → bubble visible, follows the cursor.
//   • Docked            → bubble hidden.
// Docking changes ONLY the companion's presentation — it never stops voice
// listening, agent tasks, notifications, or background work. It maps to the cursor
// overlay's activate()/deactivate(); it does not touch RealtimeVoiceService or the
// agent runners.

import AppKit

@MainActor
final class CursorCompanionController {
    static let shared = CursorCompanionController()
    private init() {}

    /// Persisted preference. Default false = undocked/visible so existing users
    /// don't lose the companion after an update.
    static let dockedKey = "mira_cursor_companion_docked"

    var isDocked: Bool {
        get { UserDefaults.standard.bool(forKey: Self.dockedKey) }   // absent → false
        set {
            UserDefaults.standard.set(newValue, forKey: Self.dockedKey)
            apply()
        }
    }

    /// Call once at launch INSTEAD of MiraCursorManager.shared.activate() so the
    /// saved dock preference is honored, and start listening for the ⌘⇧M toggle.
    func start() {
        NotificationCenter.default.addObserver(
            forName: .miraToggleCursorCompanion, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in CursorCompanionController.shared.toggle() }
        }
        apply()
    }

    func toggle() { isDocked.toggle() }

    /// Applies the current preference to the live cursor overlay. Presentation only —
    /// voice/agent state is untouched.
    func apply() {
        if isDocked {
            MiraCursorManager.shared.deactivate()
        } else {
            MiraCursorManager.shared.activate()
        }
    }
}
