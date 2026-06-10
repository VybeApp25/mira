import AVFoundation

// Live microphone input level monitor — used in SettingsView to test mic selection.
// Creates its own AVAudioEngine; call stop() when done to release the device.
final class MicLevelMonitor {
    private let engine    = AVAudioEngine()
    private var isRunning = false

    init(deviceUID: String? = nil, onLevel: @escaping (Float) -> Void) {
        let inputNode = engine.inputNode

        // Select device if a UID was provided
        if let uid = deviceUID,
           let device = AVCaptureDevice.DiscoverySession(
               deviceTypes: [.microphone],
               mediaType: .audio,
               position: .unspecified
           ).devices.first(where: { $0.uniqueID == uid }) {
            // AVAudioEngine uses CoreAudio device IDs; map via AudioObjectID
            setAudioInputDevice(uid: device.uniqueID)
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength { sum += data[i] * data[i] }
            let rms = (sum / Float(frameLength)).squareRoot()
            // Normalize 0–1 range (typical speech ~0.02–0.3 RMS)
            let normalized = min(rms * 6, 1.0)
            DispatchQueue.main.async { onLevel(normalized) }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            print("[MicLevelMonitor] start error: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    deinit { stop() }

    // MARK: - CoreAudio device selection

    private func setAudioInputDevice(uid: String) {
        var inputID = AudioDeviceID(0)
        var uidRef: CFString = uid as CFString
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            &uidRef,
            &size,
            &inputID
        )
        guard inputID != 0 else { return }
        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultInputAddress,
            0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &inputID
        )
    }
}
