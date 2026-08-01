// AudioSpectrumService.swift
// Bar levels driven by the audio that is actually playing.
//
// WHAT THIS REPLACES, and why it counts as a bug fix rather than a feature. The
// existing visualiser was six `sin()` waves with hardcoded phases and speeds:
//
//     let s = sin(t * Self.speeds[i] + Self.phases[i])
//     return 0.25 + 0.75 * (s * s)
//
// It looks exactly like a spectrum analyser and has no relationship to the
// sound. It moves identically for silence, a podcast and a drum solo, and the
// only reason nobody notices is that plausible motion is very hard to
// distinguish from real motion by eye. That is precisely what makes it worth
// removing: a display that fabricates the thing it claims to measure teaches the
// user to trust a signal that is not there.
//
// REAL LEVELS come from the ScreenCaptureKit audio stream that SystemAudioCapture
// already sets up for call transcription — same permission, same mechanism, so
// this adds no new access. `excludesCurrentProcessAudio` keeps Mira's own speech
// out of the bars, which matters because Mira talks.
//
// BANDS ARE COMPUTED WITH A REAL FFT (vDSP), not by slicing the waveform. RMS
// over time slices would give six bars that all move together — an amplitude
// meter drawn six times, which is a subtler version of the same lie. Splitting
// the SPECTRUM means the left bars genuinely track bass and the right ones
// genuinely track treble.
//
// RUNS ONLY WHILE SOMETHING IS ON SCREEN TO SEE IT. Capturing system audio
// continuously to animate bars nobody is looking at would be a real cost for
// nothing, and an uncomfortable thing to do quietly.

import Foundation
import AVFoundation
import Accelerate

/// Owns the FFT state. Deliberately NOT actor-isolated: it runs on the capture
/// queue, and hopping every audio buffer to the main actor to do arithmetic
/// would put FFT work on the thread that draws the notch.
private final class SpectrumAnalyzer: @unchecked Sendable {

    static let bandCount = 6

    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let setup: FFTSetup?
    private var window: [Float]

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    /// Magnitude spectrum -> six logarithmically spaced bands.
    func analyse(_ buffer: AVAudioPCMBuffer) -> [Double]? {
        guard let setup, let channel = buffer.floatChannelData?[0] else { return nil }
        guard Int(buffer.frameLength) >= fftSize else { return nil }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(channel, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // NORMALISE. vDSP_fft_zrip leaves the transform scaled by 2N, and these
        // are the squares of that. Without this every band pins to full height
        // on anything audible — measured: a 60Hz tone, a 250Hz tone and a 1kHz
        // tone all read 1.00 across the bottom three bands, which is six bars
        // agreeing with each other rather than a spectrum. After scaling they
        // separate: 60Hz→band 0, 250Hz→band 1, 1kHz→band 2, 12kHz→band 5.
        let scale = Float(1.0 / (4.0 * Double(fftSize) * Double(fftSize)))
        var scaled = [Float](repeating: 0, count: half)
        vDSP_vsmul(magnitudes, 1, [scale], &scaled, 1, vDSP_Length(half))
        magnitudes = scaled

        // Logarithmic band edges: hearing is logarithmic, and linear bins would
        // put five of six bars in frequencies most music barely uses.
        var bands: [Double] = []
        var lower = 1
        for index in 0..<Self.bandCount {
            let upper = min(half, Int(pow(Double(half), Double(index + 1) / Double(Self.bandCount))))
            let start = max(lower, 1), end = max(upper, start + 1)
            let slice = magnitudes[start..<min(end, half)]
            let mean = slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count)
            // Power -> dB, mapped onto a range that looks like music rather than
            // clipping to full height on anything audible.
            let db = 10 * log10(Double(max(mean, 1e-12)))
            bands.append(min(1, max(0, (db + 70) / 55)))
            lower = end
        }
        return bands
    }
}

@MainActor
final class AudioSpectrumService: ObservableObject {

    static let shared = AudioSpectrumService()

    static let bandCount = SpectrumAnalyzer.bandCount

    /// Per-band level, 0...1, newest first pass through smoothing.
    @Published private(set) var levels: [Double] = Array(repeating: 0, count: bandCount)

    /// True when the capture is live. The view falls back to its idle bars when
    /// this is false, rather than freezing at the last value it saw.
    @Published private(set) var isRunning = false

    private var capture: SystemAudioCapture?
    /// Reference counted: the collapsed ears and the expanded panel can both
    /// want this, and the first one to stop should not silence the other.
    private var holders = 0

    private let analyzer = SpectrumAnalyzer()

    private init() {}

    // MARK: - Lifecycle

    func retain() {
        holders += 1
        guard holders == 1, capture == nil else { return }
        let capture = SystemAudioCapture()
        capture.onBuffer = { [weak self] buffer in
            // Analysis happens on the capture queue; only the finished six
            // numbers cross to the main actor.
            guard let bands = self?.analyzer.analyse(buffer) else { return }
            Task { @MainActor in self?.publish(bands) }
        }
        self.capture = capture
        Task {
            do {
                try await capture.start()
                await MainActor.run { self.isRunning = true }
            } catch {
                // No Screen Recording grant, or no display. The view keeps its
                // idle bars; there is nothing useful to say mid-song.
                await MainActor.run { self.isRunning = false }
            }
        }
    }

    func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        let capture = self.capture
        self.capture = nil
        isRunning = false
        levels = Array(repeating: 0, count: Self.bandCount)
        Task { await capture?.stop() }
    }

    // MARK: - Publishing

    /// Smoothed, asymmetrically: rise fast so a transient registers, fall slower
    /// so the bars read as decay rather than flicker.
    private func publish(_ bands: [Double]) {
        var next = levels
        for index in 0..<min(bands.count, next.count) {
            let target = bands[index]
            next[index] = target > next[index]
                ? next[index] + (target - next[index]) * 0.6
                : next[index] + (target - next[index]) * 0.22
        }
        levels = next
    }
}
