import AVFoundation
import Foundation

// Onboarding narrator — uses OpenAI TTS (proxy) after sign-in for the
// real Mira voice. Falls back to AVSpeechSynthesizer for the single
// pre-auth welcome line. Completion is tracked via delegate callbacks
// (not a polling loop) so speakAndWait() reliably suspends until the
// audio actually finishes playing.

@MainActor
final class OnboardingNarrator: ObservableObject {
    static let shared = OnboardingNarrator()

    @Published private(set) var isSpeaking = false

    // OpenAI path
    private var openAIPlayer:        AVAudioPlayer?
    private let playerDelegate =     _PlayerDelegate()
    private var openAIContinuation:  CheckedContinuation<Void, Never>?

    // System TTS path (pre-auth fallback)
    private let synthesizer =        AVSpeechSynthesizer()
    private let speechDelegate =     _SpeechDelegate()
    private var systemContinuation:  CheckedContinuation<Void, Never>?

    private init() {
        playerDelegate.owner = self
        speechDelegate.owner = self
        synthesizer.delegate = speechDelegate
    }

    // MARK: - Public API

    /// Speaks `text` and suspends until the utterance finishes.
    func speakAndWait(_ text: String) async {
        stop()
        guard !text.isEmpty else { return }
        NSLog("[OnboardingNarrator] speakAndWait | signedIn=\(AccountService.shared.isSignedIn) | text=\(text.prefix(60))")
        isSpeaking = true
        // Prefer the pre-baked Realtime "Marin" clip when one is bundled for this
        // exact line. This is the true GA-Realtime Marin voice (the gpt-4o-mini-tts
        // speech endpoint has no marin voice, so the live path below would 400 and
        // fall back to the flat system voice). Bundled playback also works BEFORE
        // sign-in and fully offline.
        if let url = Self.bundledNarrationURL(for: text),
           let data = try? Data(contentsOf: url), !data.isEmpty {
            NSLog("[OnboardingNarrator] using bundled Marin clip \(url.lastPathComponent)")
            await playAudioData(data)
        } else if AccountService.shared.isSignedIn {
            await speakOpenAIAsync(text)
        } else {
            NSLog("[OnboardingNarrator] NOT signed in — using system TTS")
            await speakSystemAsync(text)
        }
        isSpeaking = false
    }

    /// URL of the pre-recorded Marin narration clip for `text`, if bundled.
    /// The filename hash MUST match the render pipeline: djb2(text + voice.rawValue),
    /// base-36. Keep in sync with `cacheURL(text:voice:)`.
    static func bundledNarrationURL(for text: String) -> URL? {
        var h: UInt64 = 5381
        for byte in (text + onboardingVoice.rawValue).utf8 { h = (h &* 33) &+ UInt64(byte) }
        return Bundle.main.url(forResource: "narration-\(String(h, radix: 36))",
                               withExtension: "mp3")
    }

    func stop() {
        // Resume any pending continuations so the caller isn't stuck
        openAIContinuation?.resume()
        openAIContinuation = nil
        systemContinuation?.resume()
        systemContinuation = nil

        openAIPlayer?.stop()
        openAIPlayer = nil
        playerDelegate.onFinish = nil

        synthesizer.stopSpeaking(at: .immediate)
        speechDelegate.onFinish = nil

        isSpeaking = false
    }

    // Fixed voice used for all onboarding narration regardless of the
    // user's saved preference (which they set in Settings after setup).
    private static let onboardingVoice: MiraVoice = .marin

    // MARK: - OpenAI TTS (requires sign-in)

    private func speakOpenAIAsync(_ text: String) async {
        let voice  = Self.onboardingVoice
        let cached = cacheURL(text: text, voice: voice)

        let data: Data
        if let d = try? Data(contentsOf: cached), !d.isEmpty {
            data = d
        } else {
            do {
                let fetched = try await synthesizeOpenAI(text: text, voice: voice)
                try? fetched.write(to: cached, options: .atomic)
                data = fetched
            } catch {
                NSLog("[OnboardingNarrator] TTS FAILED: \(error)")
                await speakSystemAsync(text)
                return
            }
        }

        await playAudioData(data, fallbackText: text)
    }

    /// Plays mp3 `data` through AVAudioPlayer and suspends until it finishes.
    /// Shared by the bundled-clip path and the live OpenAI-TTS path. If the data
    /// can't be decoded, falls back to system TTS speaking `fallbackText`.
    private func playAudioData(_ data: Data, fallbackText: String? = nil) async {
        guard let player = try? AVAudioPlayer(data: data,
                                              fileTypeHint: AVFileType.mp3.rawValue)
        else {
            if let fallbackText { await speakSystemAsync(fallbackText) }
            return
        }

        player.enableRate = true
        player.rate       = Float(MiraVoice.savedSpeed)
        player.delegate   = playerDelegate
        player.prepareToPlay()
        openAIPlayer = player

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            openAIContinuation = cont
            playerDelegate.onFinish = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.playerDelegate.onFinish  = nil
                    self.openAIPlayer             = nil
                    let cont                      = self.openAIContinuation
                    self.openAIContinuation       = nil
                    cont?.resume()
                }
            }
            player.play()
        }
    }

    private func synthesizeOpenAI(text: String, voice: MiraVoice) async throws -> Data {
        NSLog("[OnboardingNarrator] synthesizeOpenAI voice=\(voice.rawValue) len=\(text.count)")
        struct Body: Encodable {
            let model, voice, input, response_format: String
        }
        let body = Body(model: "gpt-4o-mini-tts", voice: voice.ttsVoice,
                        input: text, response_format: "mp3")
        var req = URLRequest(url: MiraBackend.openAITTSNarrationURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody   = try JSONEncoder().encode(body)
        req.timeoutInterval = 30
        guard MiraBackend.authorizeOpenAI(&req, directKey: OpenAIService.effectiveKey) else {
            throw MiraError.api("Not signed in")
        }
        let (data, resp) = try await MiraBackend.proxyData(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        NSLog("[OnboardingNarrator] TTS response status=\(status) bytes=\(data.count)")
        guard status == 200 else {
            throw MiraError.api("TTS \(status)")
        }
        return data
    }

    // MARK: - System TTS (AVSpeechSynthesizer, pre-auth)

    private func speakSystemAsync(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            systemContinuation = cont
            speechDelegate.onFinish = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.speechDelegate.onFinish = nil
                    let cont                     = self.systemContinuation
                    self.systemContinuation      = nil
                    cont?.resume()
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

    // MARK: - Cache

    private var cacheDir: URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-onboarding-narration-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func cacheURL(text: String, voice: MiraVoice) -> URL {
        var h: UInt64 = 5381
        for byte in (text + voice.rawValue).utf8 { h = (h &* 33) &+ UInt64(byte) }
        return cacheDir.appendingPathComponent("narration-\(String(h, radix: 36)).mp3")
    }
}

// MARK: - Delegate shims

final class _PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    weak var owner: OnboardingNarrator?
    var onFinish: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish?()
    }
}

final class _SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    weak var owner: OnboardingNarrator?
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
