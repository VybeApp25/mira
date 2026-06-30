import Foundation

// MARK: - CallCaptureService
//
// Phase B engine: turns a detected (or manually started) call into a live,
// speaker-separated transcript. Runs two LiveTranscriptionStreams — the mic feeds
// the `me` channel (right bubbles), system audio feeds the `caller` channel (left
// bubbles) — and routes their partial/final text into one observable CallSession.
// The notification card (Phase C) and iMessage window (Phase D) observe `current`.
// End-of-call summary + history persistence is Phase E.

@MainActor
final class CallCaptureService: ObservableObject {
    static let shared = CallCaptureService()
    private init() {}

    /// The active call, or nil when idle. UI observes this.
    @Published private(set) var current: CallSession?

    private var meStream:     LiveTranscriptionStream?
    private var callerStream: LiveTranscriptionStream?
    private var mic:          MicAudioCapture?
    private var system:       SystemAudioCapture?

    // MARK: Detector wiring (auto start/stop on known call apps)

    /// Bind to CallDetector so calls auto-start/stop. Safe to call once at launch.
    func bindToDetector() {
        let detector = CallDetector.shared
        detector.onCallStart = { [weak self] source in
            self?.startCall(source: source)
        }
        detector.onCallEnd = { [weak self] in
            self?.endCall()
        }
        detector.start()
    }

    // MARK: Start / stop

    func startCall(source: CallSource, title: String? = nil) {
        guard current == nil else { return }
        let session = CallSession(source: source, title: title)
        current = session

        // Caller (system audio) → left bubbles.
        let caller = LiveTranscriptionStream()
        caller.label = "caller"
        caller.onPartial = { [weak session] t in session?.updatePartial(t, speaker: .caller) }
        caller.onFinal   = { [weak session] t in session?.finalize(t, speaker: .caller) }
        callerStream = caller

        // Me (microphone) → right bubbles.
        let me = LiveTranscriptionStream()
        me.label = "me"
        me.onPartial = { [weak session] t in session?.updatePartial(t, speaker: .me) }
        me.onFinal   = { [weak session] t in session?.finalize(t, speaker: .me) }
        meStream = me

        Task { await caller.start() }
        Task { await me.start() }

        // Mic source.
        let micCap = MicAudioCapture()
        micCap.onBuffer = { [weak me] buf in me?.push(buf) }
        do { try micCap.start() } catch {
            NSLog("[CallCapture] mic capture failed: \(error.localizedDescription)")
        }
        mic = micCap

        // System-audio source.
        let sysCap = SystemAudioCapture()
        sysCap.onBuffer = { [weak caller] buf in caller?.push(buf) }
        system = sysCap
        Task {
            do { try await sysCap.start() } catch {
                NSLog("[CallCapture] system-audio capture failed: \(error.localizedDescription)")
                callDebugLog("system-audio: start() threw — \(error.localizedDescription)")
            }
        }
    }

    func endCall() {
        guard let session = current else { return }

        mic?.stop(); mic = nil
        if let sys = system { Task { await sys.stop() } }
        system = nil
        meStream?.stop();     meStream = nil
        callerStream?.stop(); callerStream = nil

        session.end()
        // TODO Phase E: persist session.snapshot() to history + generate summary.
        current = nil
    }
}
