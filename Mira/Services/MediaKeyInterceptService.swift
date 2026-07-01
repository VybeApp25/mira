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

    // Optimistic local state — applied immediately so key-repeat feels instant
    // even though brightness goes through a slower AppleScript round trip.
    private var volumeStep: Float = SystemVolumeControl.currentVolume()
    private var brightnessFraction: Double = 0.5
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
            callback: { _, _, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let svc = Unmanaged<MediaKeyInterceptService>.fromOpaque(refcon).takeUnretainedValue()
                return svc.handle(event: event)
            },
            userInfo: Unmanaged.passRetained(self).toOpaque()
        )

        guard let tap = eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
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

        switch keyCode {
        case NXKeyType.soundUp:
            adjustVolume(by: step)
            return nil
        case NXKeyType.soundDown:
            adjustVolume(by: -step)
            return nil
        case NXKeyType.mute:
            let muted = !SystemVolumeControl.isMuted()
            SystemVolumeControl.setMuted(muted)
            postVolumeChanged(muted ? 0 : volumeStep)
            return nil
        case NXKeyType.brightnessUp:
            adjustBrightness(by: step)
            return nil
        case NXKeyType.brightnessDown:
            adjustBrightness(by: -step)
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

    // MARK: - Brightness (AppleScript — optimistic update, async apply)

    private func adjustBrightness(by delta: Float) {
        brightnessFraction = max(0, min(1, brightnessFraction + Double(delta)))
        postBrightnessChanged(brightnessFraction)

        let fraction = brightnessFraction
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            let script = "tell application \"System Events\" to set brightness of display 1 to \(fraction)"
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
    }

    private func postBrightnessChanged(_ level: Double) {
        NotificationCenter.default.post(name: .miraBrightnessHUDChanged, object: nil,
                                         userInfo: ["level": level])
    }
}
