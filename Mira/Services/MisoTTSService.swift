import AVFoundation
import Foundation

// MARK: - Voice catalog
// Speaker indices match MisoTTS's speaker: Int parameter.
// Update misoBaseURL in MisoTTSService when the MisoLabs cloud API endpoint is available.

enum MisoVoice: String, CaseIterable, Identifiable {
    case original = "0"
    case bright   = "1"
    case smooth   = "2"
    case gentle   = "3"
    case polished = "4"
    case expert   = "5"
    case techy    = "6"
    case fun      = "7"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original:  return "Original — Natural"
        case .bright:    return "Bright — Upbeat"
        case .smooth:    return "Smooth — Warm"
        case .gentle:    return "Gentle — Clear"
        case .polished:  return "Polished — Deep"
        case .expert:    return "Expert — Authoritative"
        case .techy:     return "Techy — Crisp"
        case .fun:       return "Fun — Expressive"
        }
    }

    static var saved: MisoVoice {
        get {
            let raw = UserDefaults.standard.string(forKey: "mira_miso_voice") ?? MisoVoice.original.rawValue
            return MisoVoice(rawValue: raw) ?? .original
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mira_miso_voice") }
    }
}

// MARK: - TTS service

@MainActor
final class MisoTTSService: ObservableObject {
    static let shared = MisoTTSService()
    private init() {}

    @Published private(set) var isSpeaking = false

    // Update to MisoLabs cloud endpoint when API docs become available.
    private let misoBaseURL = "https://api.misolabs.ai/v1/tts"

    private var audioPlayer: AVAudioPlayer?
    private var currentTask: Task<Void, Never>?

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "mira_miso_key") ?? AppSecrets.misoAPIKey
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    func speak(_ text: String) {
        stop()
        guard isConfigured, !text.isEmpty else { return }
        currentTask = Task { await speakAsync(text) }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }

    private func speakAsync(_ text: String) async {
        let speaker = Int(MisoVoice.saved.rawValue) ?? 0
        var request = URLRequest(url: URL(string: misoBaseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg",        forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text":     text,
            "speaker":  speaker,
            "model_id": "miso-tts-8b"
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                isSpeaking = false
                return
            }
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue)
            audioPlayer = player
            isSpeaking  = true
            player.prepareToPlay()
            player.play()
            while player.isPlaying {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            // Task cancelled or network error
        }
        isSpeaking = false
    }
}
