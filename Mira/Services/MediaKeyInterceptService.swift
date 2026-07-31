import AppKit

// MARK: - MediaKeyInterceptService
//
// CGEventTap for volume/brightness/mute media keys, modeled on
// TextExpansionService's tap lifecycle (same create/run-loop-source/enable
// sequence), extended to listen for .systemDefined events (NX_KEYTYPE_*)
// instead of .keyDown. On a match, the event is consumed (suppressing the
// stock macOS HUD) and the change is applied here instead, so the custom
// SystemHUDView stays the single source of truth for what the user sees.
//
// Safety-critical: consuming an event ALSO suppresses the system's own
// volume/brightness change, not just its HUD. If Accessibility permission is
// ever revoked mid-session, the tap must stop consuming events — otherwise
// media keys silently do nothing (worse than just losing the custom HUD).
// startIfTrusted() re-checks AXIsProcessTrusted() on a timer and tears the
// tap down the moment trust is lost.

extension Notification.Name {
    static let miraVolumeHUDChanged     = Notification.Name("miraVolumeHUDChanged")
    static let miraBrightnessHUDChanged = Notification.Name("miraBrightnessHUDChanged")
}

private enum NXKeyType {
    static let soundUp: Int64        = 0
    static let soundDown: Int64      = 1
    static let brightnessUp: Int64   = 2
    static let brightnessDown: Int64 = 3
    static let mute: Int64           = 7
}

private let nxKeyStateDown: Int64 = 0x0A

final class MediaKeyInterceptService {
    static let shared = MediaKeyInterceptService()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var trustTimer: Timer?

    // Optimistic local state — applied immediately so key-repeat feels instant.
    // Brightness is seeded from the display's ACTUAL level (not a 0.5 guess) so
    // the HUD and the real backlight stay in sync from the first keypress.
    private var volumeStep: Float = SystemVolumeControl.currentVolume()
    private var brightnessFraction: Double = Double(BrightnessControl.currentBrightness() ?? 0.5)
    private let step: Float = 1.0 / 16.0   // matches stock macOS's 16-step granularity

    private init() {}

    // MARK: - Lifecycle

    /// Call at launch. Installs the tap only if Accessibility is already
    /// trusted, and starts polling so the tap comes up/down as trust changes
    /// (e.g. the user grants it later, or revokes it mid-session).
    func start() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileTrust() }
        }
        reconcileTrust()
    }

    private func reconcileTrust() {
        if AXIsProcessTrusted() {
            installTapIfNeeded()
        } else {
            removeTap()
        }
    }

    private func installTapIfNeeded() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let svc = Unmanaged<MediaKeyInterceptService>.fromOpaque(refcon).takeUnretainedValue()
                // macOS disables a tap that was slow to service (timeout) or on
                // certain user input — re-enable it, else media keys silently die
                // after any main-thread stall.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = svc.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return nil
                }
                return svc.handle(event: event)
            },
            userInfo: Unmanaged.passRetained(self).toOpaque()
        )

        guard let tap = eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // MUST be the MAIN run loop.
        //
        // This was serviced on a dedicated thread so a busy main thread couldn't
        // stall media keys. That crashed the app: handle(event:) builds an
        // NSEvent via NSEvent(cgEvent:), and for system-defined events that goes
        // through HIToolbox's Text Services Manager, which dispatch_asserts it
        // is on the main queue. Typing anything that moves caps-lock state walks
        // straight into it:
        //
        //   MediaKeyInterceptService.handle(event:)
        //     NSEvent.__allocating_init(cgEvent:)
        //       TSMAdjustCapsLockPressAndHold → dispatch_assert_queue_fail
        //
        // SIGTRAP, whole app down, reproducible by typing a mixed-case string.
        // The stall-resistance is not worth a crash, and the tap already
        // re-enables itself on tapDisabledByTimeout, which is the case the
        // dedicated thread was guarding against.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource!, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { EventTapThread.shared.removeSource(src) }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event handling

    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8
        else { return Unmanaged.passRetained(event) }

        let data1    = Int64(nsEvent.data1)
        let keyCode  = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8
        guard keyState == nxKeyStateDown else { return Unmanaged.passRetained(event) }

        // The tap callback runs on the dedicated event-tap thread; hop the
        // actual volume/brightness changes (and their HUD notifications) to the
        // main actor. The consume decision (return nil) stays synchronous here.
        switch keyCode {
        case NXKeyType.soundUp:
            DispatchQueue.main.async { self.adjustVolume(by: self.step) }
            return nil
        case NXKeyType.soundDown:
            DispatchQueue.main.async { self.adjustVolume(by: -self.step) }
            return nil
        case NXKeyType.mute:
            DispatchQueue.main.async {
                let muted = !SystemVolumeControl.isMuted()
                SystemVolumeControl.setMuted(muted)
                self.postVolumeChanged(muted ? 0 : self.volumeStep)
            }
            return nil
        case NXKeyType.brightnessUp:
            DispatchQueue.main.async { self.adjustBrightness(by: self.step) }
            return nil
        case NXKeyType.brightnessDown:
            DispatchQueue.main.async { self.adjustBrightness(by: -self.step) }
            return nil
        default:
            return Unmanaged.passRetained(event)
        }
    }

    // MARK: - Volume (CoreAudio — instant)

    private func adjustVolume(by delta: Float) {
        volumeStep = max(0, min(1, volumeStep + delta))
        SystemVolumeControl.setVolume(volumeStep)
        if SystemVolumeControl.isMuted() { SystemVolumeControl.setMuted(false) }
        postVolumeChanged(volumeStep)
    }

    private func postVolumeChanged(_ level: Float) {
        NotificationCenter.default.post(name: .miraVolumeHUDChanged, object: nil,
                                         userInfo: ["level": level])
    }

    // MARK: - Brightness (DisplayServices/CoreDisplay — instant, real backlight)

    private func adjustBrightness(by delta: Float) {
        // Re-read the actual level first so we track changes made elsewhere (auto
        // brightness, Control Center) instead of drifting off our own cached value.
        if let actual = BrightnessControl.currentBrightness() {
            brightnessFraction = Double(actual)
        }
        brightnessFraction = max(0, min(1, brightnessFraction + Double(delta)))
        BrightnessControl.setBrightness(Float(brightnessFraction))
        postBrightnessChanged(brightnessFraction)
    }

    private func postBrightnessChanged(_ level: Double) {
        NotificationCenter.default.post(name: .miraBrightnessHUDChanged, object: nil,
                                         userInfo: ["level": level])
    }
}
