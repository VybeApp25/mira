import AppKit
import Carbon

// MARK: - Notification names

extension Notification.Name {
    static let miraActivateVoice          = Notification.Name("miraActivateVoice")
    static let miraActivateText           = Notification.Name("miraActivateText")
    static let miraVoiceChanged           = Notification.Name("miraVoiceChanged")
    static let miraShortcutsChanged       = Notification.Name("miraShortcutsChanged")
    static let miraScreenCompanionChanged = Notification.Name("miraScreenCompanionChanged")
    static let miraChipPromptSelected     = Notification.Name("miraChipPromptSelected")
    static let miraTabSelected            = Notification.Name("miraTabSelected")
    // PTT — mirrors HeyClicky's GlobalPushToTalkShortcutMonitor events
    static let miraPushToTalkBegan        = Notification.Name("miraPushToTalkBegan")
    static let miraPushToTalkEnded        = Notification.Name("miraPushToTalkEnded")
    // Personalization
    static let miraAccentColorChanged     = Notification.Name("miraAccentColorChanged")
    static let miraPointFollowUp          = Notification.Name("miraPointFollowUp")
    static let miraAgentFlightLaunched    = Notification.Name("miraAgentFlightLaunched")
    static let miraRequestCollapse        = Notification.Name("miraRequestCollapse")
    static let miraToggleAlwaysOn         = Notification.Name("miraToggleAlwaysOn")
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
        default: break
        }
    }
    return noErr
}

// MARK: - Manager

/// Registers Carbon global hotkeys — works from any app without Accessibility permission.
/// Call start() once; call update() whenever ShortcutStore changes.
final class GlobalShortcutManager {

    private var voiceRef:   EventHotKeyRef?
    private var textRef:    EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

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
        apply(ShortcutStore.shared.voice, id: 1, into: &voiceRef)
        apply(ShortcutStore.shared.text,  id: 2, into: &textRef)
    }

    private func apply(_ config: ShortcutConfig, id: UInt32, into ref: inout EventHotKeyRef?) {
        var hkID = EventHotKeyID(signature: Self.sig, id: id)
        RegisterEventHotKey(config.keyCode, config.carbonMods,
                            hkID, GetApplicationEventTarget(), 0, &ref)
    }

    private func unregisterAll() {
        if let r = voiceRef { UnregisterEventHotKey(r) }
        if let r = textRef  { UnregisterEventHotKey(r) }
        voiceRef = nil
        textRef  = nil
    }
}
