import AppKit
import Carbon

// MARK: - Notification names

extension Notification.Name {
    static let miraActivateVoice          = Notification.Name("miraActivateVoice")
    static let miraShowClipboard          = Notification.Name("miraShowClipboard")
    static let miraActivateText           = Notification.Name("miraActivateText")
    static let miraVoiceChanged           = Notification.Name("miraVoiceChanged")
    static let miraShortcutsChanged       = Notification.Name("miraShortcutsChanged")
    static let miraScreenCompanionChanged = Notification.Name("miraScreenCompanionChanged")
    static let miraChipPromptSelected     = Notification.Name("miraChipPromptSelected")
    // Now-playing card action chip tapped (userInfo: "action" = MusicControlService.Action raw)
    static let miraMusicAction            = Notification.Name("miraMusicAction")
    static let miraTabSelected            = Notification.Name("miraTabSelected")
    // PTT — mirrors HeyClicky's GlobalPushToTalkShortcutMonitor events
    static let miraPushToTalkBegan        = Notification.Name("miraPushToTalkBegan")
    static let miraPushToTalkEnded        = Notification.Name("miraPushToTalkEnded")
    // Dictate-anywhere (⌃⌥S) — hold to speak; the transcript is inserted into the
    // focused text field of whatever app is frontmost (not Mira's own chat).
    static let miraDictateBegan           = Notification.Name("miraDictateBegan")
    static let miraDictateEnded           = Notification.Name("miraDictateEnded")
    // Draw-on-screen spatial context (⌃⌥D) — toggles the freehand draw overlay
    static let miraDrawModeToggled        = Notification.Name("miraDrawModeToggled")
    // Notch-based onboarding flow
    static let miraOnboardingStarted      = Notification.Name("miraOnboardingStarted")
    // Show/hide the island in screenshots & screen recordings (demo mode)
    static let miraShowInCaptureChanged   = Notification.Name("miraShowInCaptureChanged")
    // Personalization
    static let miraAccentColorChanged     = Notification.Name("miraAccentColorChanged")
    static let miraPointFollowUp          = Notification.Name("miraPointFollowUp")
    static let miraAgentFlightLaunched    = Notification.Name("miraAgentFlightLaunched")
    static let miraRequestCollapse        = Notification.Name("miraRequestCollapse")
    static let miraIslandHeightChanged    = Notification.Name("miraIslandHeightChanged")
    static let miraToggleAlwaysOn         = Notification.Name("miraToggleAlwaysOn")
    // "Hey Mira" wake word enabled/disabled (Settings toggle) — NotchManager
    // reads WakeWordService.isEnabledPreference and starts/pauses accordingly.
    static let miraToggleWakeWord         = Notification.Name("miraToggleWakeWord")
    // Pin the island open (suppress hover auto-collapse) while a multi-step flow
    // needs the user to leave Mira and come back — e.g. the Knowledge Import
    // round-trip (copy prompt → another assistant → copy reply → back to Mira).
    // userInfo["pinned"] is a Bool. Pins are reference-counted in NotchManager.
    static let miraPinIsland              = Notification.Name("miraPinIsland")
    // Temporarily drop the island panel below normal windows so a system-owned
    // modal (e.g. Sparkle's update dialog) isn't occluded by the notch overlay.
    // Posted by UpdateService around the update session; observed by
    // MiraIslandWindowManager. Resume restores the island's normal window level.
    static let miraSuspendForModal        = Notification.Name("miraSuspendForModal")
    static let miraResumeFromModal        = Notification.Name("miraResumeFromModal")
    // A Finder (or other app) file drag entered the notch drop zone — NotchManager
    // expands the island; MiraIslandView switches to the Shelf tab. Posted by
    // NotchDropZoneController.
    static let miraDragEnteredNotch       = Notification.Name("miraDragEnteredNotch")
}

// MARK: - Carbon callback (free function — no captures, safe as C function pointer)

private func miraHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event:   EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    var hkID = EventHotKeyID()
    GetEventParameter(event,
                      EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil, MemoryLayout<EventHotKeyID>.size, nil,
                      &hkID)
    let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    DispatchQueue.main.async {
        switch hkID.id {
        case 1:
            if isRelease {
                // PTT key up — 400ms tail then commit
                NotificationCenter.default.post(name: .miraPushToTalkEnded, object: nil)
            } else {
                // PTT key down — expand island + begin capture
                NotificationCenter.default.post(name: .miraActivateVoice,   object: nil)
                NotificationCenter.default.post(name: .miraPushToTalkBegan, object: nil)
            }
        case 2:
            if !isRelease {
                NotificationCenter.default.post(name: .miraActivateText, object: nil)
            }
        case 3:
            if !isRelease {
                NotificationCenter.default.post(name: .miraDrawModeToggled, object: nil)
            }
        case 4:
            if !isRelease {
                NotificationCenter.default.post(name: .miraShowClipboard, object: nil)
            }
        case 5:
            // Dictate-anywhere is hold-to-talk: press begins capture, release commits.
            if isRelease {
                NotificationCenter.default.post(name: .miraDictateEnded, object: nil)
            } else {
                NotificationCenter.default.post(name: .miraDictateBegan, object: nil)
            }
        default: break
        }
    }
    return noErr
}

// MARK: - Manager

/// Registers Carbon global hotkeys — works from any app without Accessibility permission.
/// Call start() once; call update() whenever ShortcutStore changes.
final class GlobalShortcutManager {

    private var voiceRef:     EventHotKeyRef?
    private var textRef:      EventHotKeyRef?
    private var drawRef:      EventHotKeyRef?
    private var dictateRef:   EventHotKeyRef?
    private var clipboardRef: EventHotKeyRef?
    private var handlerRef:   EventHandlerRef?

    // "MIRA" encoded as OSType
    private static let sig: OSType = 0x4D495241

    func start() {
        installHandler()
        register()
    }

    func update() {
        unregisterAll()
        register()
    }

    // MARK: - Private

    private func installHandler() {
        guard handlerRef == nil else { return }
        // Register both pressed and released so PTT can detect key-up
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(),
                            miraHotKeyHandler, specs.count, &specs, nil, &handlerRef)
    }

    private func register() {
        apply(ShortcutStore.shared.voice,   id: 1, into: &voiceRef)
        apply(ShortcutStore.shared.text,    id: 2, into: &textRef)
        apply(ShortcutStore.shared.draw,    id: 3, into: &drawRef)
        apply(ShortcutStore.shared.dictate, id: 5, into: &dictateRef)
        // ⌃⌘V — clipboard history panel (hardcoded, not user-configurable yet)
        var clipHKID = EventHotKeyID(signature: Self.sig, id: 4)
        // keyCode 9 = V, carbonMods = cmdKey | controlKey
        RegisterEventHotKey(9, UInt32(cmdKey | controlKey),
                            clipHKID, GetApplicationEventTarget(), 0, &clipboardRef)
    }

    private func apply(_ config: ShortcutConfig, id: UInt32, into ref: inout EventHotKeyRef?) {
        var hkID = EventHotKeyID(signature: Self.sig, id: id)
        RegisterEventHotKey(config.keyCode, config.carbonMods,
                            hkID, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregisterAll() {
        if let r = voiceRef     { UnregisterEventHotKey(r) }
        if let r = textRef      { UnregisterEventHotKey(r) }
        if let r = drawRef      { UnregisterEventHotKey(r) }
        if let r = dictateRef   { UnregisterEventHotKey(r) }
        if let r = clipboardRef { UnregisterEventHotKey(r) }
        voiceRef     = nil
        textRef      = nil
        drawRef      = nil
        dictateRef   = nil
        clipboardRef = nil
    }
}
