import CoreAudio
import AudioToolbox

// MARK: - SystemVolumeControl
//
// CoreAudio volume read/write for the custom volume HUD. Extends
// AudioOutputRoute's read-only device-lookup template with writes.
//
// kAudioHardwareServiceDeviceProperty_VirtualMainVolume must go through the
// AudioHardwareService* calls, NOT plain AudioObjectSetPropertyData/GetPropertyData
// — using the plain AudioObject calls on this property silently fails (a common
// trap). Mute uses the ordinary AudioObject calls on kAudioDevicePropertyMute.

enum SystemVolumeControl {

    static func currentVolume() -> Float {
        guard let device = AudioOutputRoute.defaultOutputDevice() else { return 0 }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain)
        let status = AudioHardwareServiceGetPropertyData(device, &addr, 0, nil, &size, &volume)
        return status == noErr ? volume : 0
    }

    static func setVolume(_ level: Float) {
        guard let device = AudioOutputRoute.defaultOutputDevice() else { return }
        var volume = Float32(max(0, min(1, level)))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain)
        AudioHardwareServiceSetPropertyData(
            device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
    }

    static func isMuted() -> Bool {
        guard let device = AudioOutputRoute.defaultOutputDevice() else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = AudioOutputRoute.defaultOutputDevice() else { return }
        var value = UInt32(muted ? 1 : 0)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
