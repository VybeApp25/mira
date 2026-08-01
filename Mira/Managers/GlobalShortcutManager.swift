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
    /// ⌃⌥P — open the notch on "Write my prompt", ready to type.
    static let miraComposePrompt          = Notification.Name("miraComposePrompt")
    /// Posted once the panel is up, so the composer field can take focus.
    static let miraFocusComposer          = Notification.Name("miraFocusComposer")
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
    static let miraToggleCursorCompanion  = Notification.Name("miraToggleCursorCompanion")
    // Module carousel navigation + notch snooze (MacNotch parity: it binds both).
    static let miraModulePrev             = Notification.Name("miraModulePrev")
    static let miraModuleNext             = Notification.Name("miraModuleNext")
    static let miraToggleSnooze           = Notification.Name("miraToggleSnooze")
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
        case 6:
            if !isRelease {
                NotificationCenter.default.post(name: .miraToggleCursorCompanion, object: nil)
            }
        // These three are edge-triggered, so they MUST ignore the release.
        // This handler is installed for pressed AND released (push-to-talk needs
        // both), so an unguarded case fires twice per keypress: the carousel
        // skipped every other module, and ⌃⌥Z toggled snooze on and then
        // straight back off, which read as the shortcut being dead.
        case 7:
            if !isRelease { NotificationCenter.default.post(name: .miraModulePrev,   object: nil) }
        case 8:
            if !isRelease { NotificationCenter.default.post(name: .miraModuleNext,   object: nil) }
        case 9:
            if !isRelease { NotificationCenter.default.post(name: .miraToggleSnooze, object: nil) }
        case 10:
            // Edge-triggered like the three above: this handler runs for pressed
            // AND released, so an unguarded case fires twice per press.
            if !isRelease { NotificationCenter.default.post(name: .miraComposePrompt, object: nil) }
        default: break
        }
    }
    return noErr
}

// MARK: - Manager

/// Registers Carbon global hotkeys — works from any app without Accessibility permission.
/// Call start() once; call update() whenever ShortcutStore changes.
final class GlobalShortcutManager {

    private var composeRef:   EventHotKeyRef?
    private var voiceRef:     EventHotKeyRef?
    private var textRef:      EventHotKeyRef?
    private var drawRef:      EventHotKeyRef?
    private var dictateRef:   EventHotKeyRef?
    private var clipboardRef: EventHotKeyRef?
    private var cursorRef:    EventHotKeyRef?
    private var prevRef:      EventHotKeyRef?
    private var nextRef:      EventHotKeyRef?
    private var snoozeRef:    EventHotKeyRef?
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
        // ⌘⇧M — dock/undock the cursor companion (hardcoded, keyCode 46 = M)
        let cursorHKID = EventHotKeyID(signature: Self.sig, id: 6)
        RegisterEventHotKey(46, UInt32(cmdKey | shiftKey),
                            cursorHKID, GetApplicationEventTarget(), 0, &cursorRef)

        // Module carousel: ⌃⌥← / ⌃⌥→ (keyCodes 123/124). With 26 modules
        // registered, reaching a non-pinned one meant opening the browser every
        // time; arrows make the carousel usable without the mouse.
        RegisterEventHotKey(123, UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: Self.sig, id: 7),
                            GetApplicationEventTarget(), 0, &prevRef)
        RegisterEventHotKey(124, UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: Self.sig, id: 8),
                            GetApplicationEventTarget(), 0, &nextRef)

        // ⌃⌥P — "prompt". The one-keypress entry to the composer: the point of
        // the feature is that you never go looking for a panel.
        RegisterEventHotKey(35, UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: Self.sig, id: 10),
                            GetApplicationEventTarget(), 0, &composeRef)

        // ⌃⌥Z — snooze the notch. MacNotch binds this too: sometimes you want
        // the top of the screen to stop reacting to your cursor for a while.
        RegisterEventHotKey(6, UInt32(controlKey | optionKey),
                            EventHotKeyID(signature: Self.sig, id: 9),
                            GetApplicationEventTarget(), 0, &snoozeRef)
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
        if let r = cursorRef    { UnregisterEventHotKey(r) }
        if let r = prevRef      { UnregisterEventHotKey(r) }
        if let r = nextRef      { UnregisterEventHotKey(r) }
        if let r = snoozeRef    { UnregisterEventHotKey(r) }
        voiceRef     = nil
        textRef      = nil
        drawRef      = nil
        dictateRef   = nil
        clipboardRef = nil
        cursorRef    = nil
        prevRef      = nil
        nextRef      = nil
        snoozeRef    = nil
    }
}
