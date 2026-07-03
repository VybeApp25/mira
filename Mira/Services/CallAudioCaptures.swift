@preconcurrency import AVFoundation
import Foundation
import ScreenCaptureKit
import CoreMedia

// MARK: - Microphone capture (the user → right-side bubbles)
//
// A standalone AVAudioEngine input tap. Independent of AssemblyAIStreamingService
// / RealtimeVoiceService so it can run during a call; if always-on voice holds the
// input device this may contend — coordinating that is a follow-up.

final class MicAudioCapture: @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var engine = AVAudioEngine()

    func start() throws {
        engine = AVAudioEngine()
        let node = engine.inputNode
        let fmt  = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            self?.onBuffer?(buf)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }
}

// MARK: - System audio capture (the caller → left-side bubbles)
//
// ScreenCaptureKit audio-only stream. `excludesCurrentProcessAudio` keeps Mira's
// own sounds/TTS out of the caller channel. Video is configured minimally and its
// frames ignored — SCStream requires a content filter even for audio capture.

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "today.getmira.systemaudio")

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Mira.SystemAudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for audio capture."])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio               = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate                  = 48_000
        cfg.channelCount                = 2
        // Video is required by SCStream even for audio-only; use the display size
        // at a low frame rate (we never read .screen frames). A 2x2 size made the
        // stream fail to deliver audio.
        cfg.width                = display.width
        cfg.height               = display.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)   // ~0.5 fps, frames ignored

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // SCStreamOutput — called on `queue`.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = sampleBuffer.asPCMBuffer else { return }
        onBuffer?(pcm)
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer (copying, so it outlives the callback)

extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(self),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
