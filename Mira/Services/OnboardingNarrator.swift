import AVFoundation
import Foundation

// Two-engine narration for onboarding:
//   • Before sign-in  → AVSpeechSynthesizer (on-device, always available)
//   • After sign-in   → OpenAI TTS via proxy (richer voice, same path as VoicePreviewService)
//
// NotchOnboardingManager signs the user in first, then all demo narration
// runs through OpenAI so every line sounds like Mira's real voice.

@MainActor
final class OnboardingNarrator: ObservableObject {
    static let shared = OnboardingNarrator()

    @Published private(set) var isSpeaking = false

    // System TTS (pre-auth)
    private let synthesizer    = AVSpeechSynthesizer()
    private let speechDelegate = _SpeechDelegate()

    // OpenAI TTS (post-auth)
    private var openAITask: Task<Void, Never>?
    private var openAIPlayer: AVAudioPlayer?

    private init() {
        synthesizer.delegate = speechDelegate
    }

    // MARK: - Public API

    /// Speaks `text` and suspends until done. Picks engine based on auth state.
    func speakAndWait(_ text: String) async {
        stop()
        guard !text.isEmpty else { return }
        isSpeaking = true
        if AccountService.shared.isSignedIn {
            await speakOpenAIAsync(text)
        } else {
            await speakSystemAsync(text)
        }
        isSpeaking = false
    }

    func stop() {
        // OpenAI path
        openAITask?.cancel()
        openAITask = nil
        openAIPlayer?.stop()
        openAIPlayer = nil
        // System path
        synthesizer.stopSpeaking(at: .immediate)
        speechDelegate.onFinish = nil
        isSpeaking = false
    }

    // MARK: - System TTS (AVSpeechSynthesizer)

    private func speakSystemAsync(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            speechDelegate.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.speechDelegate.onFinish = nil
                    cont.resume()
                }
            }
            synthesizer.speak(systemUtterance(for: text))
        }
    }

    private func systemUtterance(for text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = bestSystemVoice()
        u.rate  = 0.50
        u.pitchMultiplier = 1.02
        u.volume = 1.0
        return u
    }

    private func bestSystemVoice() -> AVSpeechSynthesisVoice? {
        let ids = [
            "com.apple.voice.premium.en-US.Zoe",
            "com.apple.ttsbundle.Samantha-premium",
            "com.apple.voice.premium.en-US.Evan",
            "com.apple.ttsbundle.Alex-compact",
        ]
        for id in ids { if let v = AVSpeechSynthesisVoice(identifier: id) { return v } }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - OpenAI TTS

    private func speakOpenAIAsync(_ text: String) async {
        let voice = MiraVoice.saved
        let cached = cacheURL(text: text, voice: voice)

        let data: Data
        if FileManager.default.fileExists(atPath: cached.path),
           let d = try? Data(contentsOf: cached) {
            data = d
        } else {
            guard let fetched = try? await synthesizeOpenAI(text: text, voice: voice) else {
                // graceful fallback if network fails mid-onboarding
                await speakSystemAsync(text)
                return
            }
            try? fetched.write(to: cached, options: .atomic)
            data = fetched
        }

        guard let player = try? AVAudioPlayer(data: data,
                                              fileTypeHint: AVFileType.mp3.rawValue)
        else { await speakSystemAsync(text); return }

        player.enableRate = true
        player.rate = Float(MiraVoice.savedSpeed)
        player.prepareToPlay()
        openAIPlayer = player
        player.play()

        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        openAIPlayer = nil
    }

    private func synthesizeOpenAI(text: String, voice: MiraVoice) async throws -> Data {
        struct Body: Encodable {
            let model, voice, input, response_format: String
        }
        let body = Body(model: "gpt-4o-mini-tts", voice: voice.ttsVoice,
                        input: text, response_format: "mp3")
        var req = URLRequest(url: MiraBackend.openAITTSURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 30
        guard MiraBackend.authorizeOpenAI(&req, directKey: OpenAIService.effectiveKey) else {
            throw MiraError.api("Not signed in")
        }
        let (data, resp) = try await MiraBackend.proxyData(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiraError.api("TTS failed")
        }
        return data
    }

    private var cacheDir: URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-onboarding-narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func cacheURL(text: String, voice: MiraVoice) -> URL {
        var h: UInt64 = 5381
        for byte in (text + voice.rawValue).utf8 { h = (h &* 33) &+ UInt64(byte) }
        return cacheDir.appendingPathComponent("narration-\(String(h, radix: 36)).mp3")
    }

    // MARK: - Legacy step lines (used by old OnboardingView)

    static func line(for step: OnboardingStep) -> String? {
        switch step {
        case .intro:           return "Hey — I'm Mira. I live right here in your notch and I'm always ready to help."
        case .signIn:          return "Sign in or create your account. I handle all the AI keys — you never have to."
        case .voicePersona:    return "Pick the voice you want me to use."
        case .knowledgeImport: return "Import your profile from ChatGPT or Claude if you'd like. It stays on your Mac."
        case .discovery:       return "How did you hear about me?"
        case .permission(let p):
            switch p {
            case .microphone:     return "I need microphone access to hear you."
            case .screenRecording:return "Allow Screen Recording so I can see your screen and guide you."
            case .accessibility:  return "Accessibility lets me click and type in your apps."
            }
        case .agentFolder:     return "This is where I'll save files when I run tasks for you."
        case .demoAgent:       return "Want to see me work? I'll build a webpage right now."
        case .paywall:         return "Start free, or upgrade anytime."
        case .done:            return "You're all set. I'm right here whenever you need me."
        }
    }
}

// MARK: - AVSpeechSynthesizer delegate shim

private final class _SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) { onFinish?() }
}
