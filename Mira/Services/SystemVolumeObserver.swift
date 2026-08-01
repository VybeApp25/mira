// SystemVolumeObserver.swift
// Posts the volume HUD for ANY volume change, not just one made with the media
// keys.
//
// MediaKeyInterceptService already drives the HUD when you press the physical
// key, and that stays the fast path. But it is the only path, which means
// changing the volume from Control Center, from the Touch Bar, from a script, or
// from a headset's own buttons moved the volume with no feedback in the notch at
// all — the HUD was tied to the input method rather than to the thing it
// reports. MacNotch registers CoreAudio property listeners for exactly this
// (`AudioObjectAddPropertyListenerBlock(volume)` / `(mute)` appear in its
// binary alongside its key tap).
//
// Duplicate posts are harmless: both paths report the same level, and the strip
// simply re-renders the same value.

import Foundation
import CoreAudio
import AudioToolbox

@MainActor
final class SystemVolumeObserver {

    static let shared = SystemVolumeObserver()

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var listening = false
    /// Last level announced, so a listener that fires several times for one
    /// change doesn't restart the HUD's timer repeatedly.
    private var lastPosted: Float = -1

    private init() {}

    func start() {
        guard !listening else { return }
        device = Self.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }

        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                         kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main) { [weak self] _, _ in
                Task { @MainActor in self?.announce() }
            }
        }

        // The default output device changes when headphones go in, and the
        // listeners above are bound to a specific device — without this the HUD
        // would go quiet the first time the user plugged something in.
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.listening = false
                self.start()
                // Which device sound is coming out of is worth a line in the
                // notch — it is the thing you actually want confirmed when you
                // put headphones in. MacNotch surfaces the same ("audio output
                // labels fit better on built-in notches").
                if let name = Self.deviceName(self.device) {
                    NotificationCenter.default.post(name: .miraAudioOutputChanged,
                                                    object: nil, userInfo: ["name": name])
                }
            }
        }

        listening = true
        lastPosted = SystemVolumeControl.isMuted() ? 0 : SystemVolumeControl.currentVolume()
    }

    private func announce() {
        let level = SystemVolumeControl.isMuted() ? 0 : SystemVolumeControl.currentVolume()
        guard abs(level - lastPosted) > 0.001 else { return }
        lastPosted = level
        NotificationCenter.default.post(name: .miraVolumeHUDChanged, object: nil,
                                        userInfo: ["level": level])
    }

    static func deviceName(_ id: AudioObjectID) -> String? {
        guard id != kAudioObjectUnknown else { return nil }
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
        let value = name as String
        return value.isEmpty ? nil : value
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &id)
        return id
    }
}
