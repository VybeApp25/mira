import AppKit

extension Notification.Name {
    static let miraActivateVoice = Notification.Name("miraActivateVoice")
    static let miraActivateText  = Notification.Name("miraActivateText")
}

/// Monitors global modifier-key combinations for hands-free Mira activation.
/// Uses NSEvent.flagsChanged which does NOT require Accessibility permission
/// (only keyDown global monitors need it).
///
///   ⌃ + ⌥   →  voice mode
///   ⌃ + fn  →  text mode (fn shows as .function in modifierFlags)
final class GlobalShortcutManager {

    var onVoiceShortcut: (() -> Void)?
    var onTextShortcut:  (() -> Void)?

    private var monitor: Any?

    // Track last fired combo to require a "release and re-press" before firing again
    private var lastFired: String?

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async { self?.evaluate(event) }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    // MARK: - Private

    private func evaluate(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌃ + ⌥ only (no command, no shift, no fn)
        let voiceCombo: NSEvent.ModifierFlags = [.control, .option]
        let voiceExact = flags == voiceCombo

        // ⌃ + fn only (no command, no shift, no option)
        let textCombo: NSEvent.ModifierFlags  = [.control, .function]
        let textExact  = flags == textCombo

        if voiceExact {
            guard lastFired != "voice" else { return }
            lastFired = "voice"
            onVoiceShortcut?()
        } else if textExact {
            guard lastFired != "text" else { return }
            lastFired = "text"
            onTextShortcut?()
        } else {
            // Any other change (e.g. keys released) resets the guard
            lastFired = nil
        }
    }
}
