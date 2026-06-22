import CoreAudio
import Foundation

// MARK: - AudioOutputRoute
//
// Tells whether system audio is currently going to an EXTERNAL output (headphones,
// AirPods/Bluetooth, USB, HDMI/DisplayPort, Thunderbolt, AirPlay) rather than the
// built-in speaker. Used to gate barge-in: streaming the mic WHILE Mira is speaking
// is safe on headphones, but on the built-in speaker it echoes Mira's own voice back
// into the mic and self-interrupts. So barge-in is headphones-only by design.
//
// CAVEAT: the 3.5mm headphone jack reports `kAudioDeviceTransportTypeBuiltIn` on some
// Macs, so wired-jack headphones are treated as the built-in speaker (no barge-in).
// AirPods / Bluetooth / USB headsets report their own transport and work correctly.

enum AudioOutputRoute {

    /// True when the default output device is NOT the built-in speaker.
    static var isExternalOutput: Bool {
        guard let device = defaultOutputDevice(),
              let transport = transportType(of: device) else { return false }
        return transport != kAudioDeviceTransportTypeBuiltIn
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32? {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }
}
