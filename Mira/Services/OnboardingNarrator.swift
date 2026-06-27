import AVFoundation
import Foundation

// Speaks each onboarding step aloud using the same OpenAI TTS proxy path as
// VoicePreviewService. Audio is cached on disk so revisiting a step never
// re-bills. Uses MiraVoice.saved so the user hears their chosen voice the
// moment they pick it on the persona step.

@MainActor
final class OnboardingNarrator: ObservableObject {
    static let shared = OnboardingNarrator()
    private init() {}

    @Published private(set) var isSpeaking = false

    private var player: AVAudioPlayer?
    private var currentTask: Task<Void, Never>?

    private var cacheDir: URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mira-onboarding-narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - Narration lines

    static func line(for step: OnboardingStep) -> String? {
        switch step {
        case .intro:
            return "Hey — I'm Mira. I live right in your notch and I'm always ready to help. Let's get you set up. It'll only take a minute."
        case .signIn:
            return "First, sign in or create your account. I handle all the AI keys behind the scenes — you never have to manage them yourself."
        case .voicePersona:
            return "Now pick the voice you want me to use. Scroll through the cards and tap one to hear a preview. Take your time — choose the one that feels right."
        case .knowledgeImport:
            return "If you already use ChatGPT or Claude, you can import your profile so I know you from day one. This stays on your Mac and is never shared. Skip it if you'd rather do it later."
        case .discovery:
            return "Quick one — how did you hear about me? Just tap an option and we'll keep moving."
        case .permission(let p):
            switch p {
            case .microphone:
                return "I need to hear you. Tap Allow Microphone so I can listen for your voice."
            case .screenRecording:
                return "Now I need to see your screen, so I can point to things and guide you through any app. Open System Settings and flip my toggle on."
            case .accessibility:
                return "Last one. Accessibility lets me click and type in your apps when you ask me to. Same thing — System Settings, find Mira, and turn me on."
            }
        case .agentFolder:
            return "This is where I'll save files when I run tasks for you. The default is fine for most people. Tap continue whenever you're ready."
        case .demoAgent:
            return "Want to see me work right now? Hit Run the demo and I'll build you a webpage while we finish setup. You can watch it live in the Agents tab."
        case .paywall:
            return "Almost done. Start free, or upgrade to Pro or Ultra for more agent runs. You can change your plan anytime in Settings."
        case .done:
            return "You're all set. Hover the notch to open me. Hold Control-Option to talk. I'll be right here whenever you need me."
        }
    }

    // MARK: - Public API

    func speak(for step: OnboardingStep) {
        stop()
        guard let text = Self.line(for: step), !text.isEmpty else { return }
        let voice = MiraVoice.saved
        currentTask = Task { await speakAsync(text, voice: voice) }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        player?.stop()
        player = nil
        isSpeaking = false
    }

    // MARK: - Private

    private func cacheURL(text: String, voice: MiraVoice) -> URL {
        var h: UInt64 = 5381
        for byte in (text + voice.rawValue).utf8 { h = (h &* 33) &+ UInt64(byte) }
        return cacheDir.appendingPathComponent("narration-\(String(h, radix: 36)).mp3")
    }

    private func speakAsync(_ text: String, voice: MiraVoice) async {
        let cached = cacheURL(text: text, voice: voice)

        let data: Data
        if FileManager.default.fileExists(atPath: cached.path),
           let d = try? Data(contentsOf: cached) {
            data = d
        } else {
            guard let fetched = try? await synthesize(text: text, voice: voice) else { return }
            if Task.isCancelled { return }
            try? fetched.write(to: cached, options: .atomic)
            data = fetched
        }

        guard !Task.isCancelled,
              let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
        else { return }

        p.enableRate = true
        p.rate = Float(MiraVoice.savedSpeed)
        p.prepareToPlay()
        player = p
        isSpeaking = true
        p.play()

        while p.isPlaying && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        isSpeaking = false
    }

    private func synthesize(text: String, voice: MiraVoice) async throws -> Data {
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
            throw MiraError.api("Not signed in.")
        }
        let (data, resp) = try await MiraBackend.proxyData(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw MiraError.api("TTS failed")
        }
        return data
    }
}
