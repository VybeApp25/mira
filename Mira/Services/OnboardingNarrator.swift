import AVFoundation
import Foundation

// Speaks onboarding narration using the on-device AVSpeechSynthesizer so it
// works before sign-in and can't be interrupted by the realtime voice session.

@MainActor
final class OnboardingNarrator: ObservableObject {
    static let shared = OnboardingNarrator()

    @Published private(set) var isSpeaking = false

    private let synthesizer    = AVSpeechSynthesizer()
    private let speechDelegate = _SpeechDelegate()

    private init() {
        synthesizer.delegate = speechDelegate
    }

    // MARK: - Public API

    /// Speaks `text` and suspends until the utterance finishes (or is stopped).
    func speakAndWait(_ text: String) async {
        stop()
        guard !text.isEmpty else { return }
        isSpeaking = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            speechDelegate.onFinish = { [weak self] in
                Task { @MainActor in
                    self?.isSpeaking = false
                    self?.speechDelegate.onFinish = nil
                    continuation.resume()
                }
            }
            synthesizer.speak(utterance(for: text))
        }
    }

    /// Fire-and-forget variant (used by legacy OnboardingView).
    func speak(for step: OnboardingStep) {
        guard let text = Self.line(for: step) else { return }
        stop()
        isSpeaking = true
        speechDelegate.onFinish = { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
                self?.speechDelegate.onFinish = nil
            }
        }
        synthesizer.speak(utterance(for: text))
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speechDelegate.onFinish = nil
        isSpeaking = false
    }

    // MARK: - Narration script

    static func line(for step: OnboardingStep) -> String? {
        switch step {
        case .intro:
            return "Hey — I'm Mira. I live right here in your notch and I'm always ready to help. Let's get you set up in just a minute."
        case .signIn:
            return "First, sign in or create your account. I handle all the AI keys behind the scenes — you never have to manage them yourself."
        case .voicePersona:
            return "Pick the voice you want me to use. You can hear a preview of each one. Choose whichever feels right."
        case .knowledgeImport:
            return "If you already use ChatGPT or Claude, you can import your profile so I know you from day one. This stays on your Mac and is never shared."
        case .discovery:
            return "Quick one — how did you hear about me? Just tap an option and we'll keep moving."
        case .permission(let p):
            switch p {
            case .microphone:
                return "I need to hear you. Allow microphone access so I can listen for your voice."
            case .screenRecording:
                return "Now I need to see your screen so I can point at things and guide you through any app. Open System Settings and flip my toggle on."
            case .accessibility:
                return "Last one. Accessibility lets me click and type in your apps when you ask. System Settings, find Mira, and turn me on."
            }
        case .agentFolder:
            return "This is where I'll save files when I run tasks for you. The default works great for most people."
        case .demoAgent:
            return "Want to see me work right now? Hit Run the demo and I'll build you a webpage while we finish setup."
        case .paywall:
            return "Start free, or upgrade to Pro or Ultra for more agent runs. You can change your plan anytime in Settings."
        case .done:
            return "You're all set. Hover the notch to open me. Hold Control-Option to talk. I'll be right here."
        }
    }

    // MARK: - Private

    private func utterance(for text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice()
        u.rate  = 0.50
        u.pitchMultiplier = 1.02
        u.volume = 1.0
        return u
    }

    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let ids = [
            "com.apple.voice.premium.en-US.Zoe",
            "com.apple.ttsbundle.Samantha-premium",
            "com.apple.voice.premium.en-US.Evan",
            "com.apple.ttsbundle.Alex-compact",
        ]
        for id in ids {
            if let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}

// MARK: - Delegate shim

private final class _SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }
}
