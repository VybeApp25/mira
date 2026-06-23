// WakeWordService.swift
// Always-on, low-power wake word detection using on-device SFSpeechRecognizer.
// When "hey mira" is heard: posts .miraActivateVoice (NotchManager expands + voice starts).
// Automatically pauses while a Realtime session is active; resumes on idle.

import Speech
import AVFoundation

@MainActor
final class WakeWordService: NSObject, ObservableObject {

    @Published private(set) var isListening = false

    // User toggle (Settings → "Hey Mira" wake word). Defaults ON so existing
    // behavior is preserved when the key was never written. start() self-gates
    // on this, so every caller (launch + collapse-restart) becomes a no-op when
    // the user has turned the wake word off.
    static let enabledKey = "mira_wake_word_enabled"
    static var isEnabledPreference: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: enabledKey)
    }

    // Trigger phrases — includes common mishearings
    private let triggers = ["hey mira", "hey mirror", "hey mirra", "okay mira", "hi mira"]

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine = AVAudioEngine()
    private var request:    SFSpeechAudioBufferRecognitionRequest?
    private var task:       SFSpeechRecognitionTask?
    private var enabled     = false

    // MARK: - Public API

    func start() {
        guard !enabled else { return }
        guard Self.isEnabledPreference else { return }
        enabled = true
        Task { await requestPermissionAndBegin() }
    }

    func pause() {
        guard enabled else { return }
        enabled = false
        teardown()
    }

    // MARK: - Permission + cycle

    private func requestPermissionAndBegin() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { _ in cont.resume(returning: ()) }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized, enabled else { return }
        beginCycle()
    }

    private func beginCycle() {
        guard enabled, let recognizer, recognizer.isAvailable else { return }

        audioEngine  = AVAudioEngine()
        request      = SFSpeechAudioBufferRecognitionRequest()
        guard let request else { return }

        // On-device recognition: no network dependency, no 1-min server limit
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults  = true

        let node = audioEngine.inputNode
        let fmt  = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            isListening = false
            scheduleRestart()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.enabled else { return }

                if let text = result?.bestTranscription.formattedString.lowercased(),
                   self.triggers.contains(where: { text.contains($0) }) {
                    self.handleDetection()
                    return
                }

                // Recognition task ends naturally (~60 s on-device) — restart it
                if error != nil || result?.isFinal == true {
                    self.teardown()
                    self.scheduleRestart()
                }
            }
        }
    }

    private func handleDetection() {
        pause()
        NotificationCenter.default.post(name: .miraActivateVoice, object: nil)
    }

    private func scheduleRestart() {
        guard enabled else { return }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if self.enabled { self.beginCycle() }
        }
    }

    private func teardown() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        request?.endAudio()
        task?.finish()
        request     = nil
        task        = nil
        isListening = false
    }
}
