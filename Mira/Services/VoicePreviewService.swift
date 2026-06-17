// VoicePreviewService.swift
// Generates the in-app voice previews live via OpenAI text-to-speech instead of
// shipping bundled audio clips. Every voice speaks the same line
// (MiraVoice.previewPhrase) so they're directly comparable.
//
// Requests route through MiraBackend.openAITTSURL — the backend proxy in proxy
// mode (no key in the client), OpenAI directly otherwise. Results are cached on
// disk per voice, so re-tapping a voice replays instantly and never re-bills.

import Foundation
@preconcurrency import AVFoundation

@MainActor
final class VoicePreviewService: NSObject, ObservableObject {

    static let shared = VoicePreviewService()
    private override init() { super.init() }

    /// The voice whose preview is currently audible (drives the stop icon).
    @Published private(set) var playingVoice: MiraVoice?
    /// The voice currently being synthesized/fetched (drives a spinner).
    @Published private(set) var loadingVoice: MiraVoice?

    private var player: AVAudioPlayer?
    private var fetchTask: Task<Void, Never>?

    private var cacheDir: URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mira-voice-previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Cache file for a voice, versioned by the phrase. If the preview line ever
    /// changes, the filename changes too, so a stale clip can never silently play.
    /// Uses a deterministic hash (Swift's String.hashValue is randomized per run).
    private func cacheURL(for voice: MiraVoice) -> URL {
        var h: UInt64 = 5381
        for byte in MiraVoice.previewPhrase.utf8 { h = (h &* 33) &+ UInt64(byte) }
        let tag = String(h, radix: 36)
        return cacheDir.appendingPathComponent("\(voice.rawValue)-\(tag).mp3")
    }

    /// Tap handler: stops if this voice is already playing/loading, else fetches
    /// (or replays from cache) and plays it.
    func toggle(_ voice: MiraVoice) {
        if playingVoice == voice || loadingVoice == voice {
            stop()
            return
        }
        stop()

        // Cached clip → play immediately.
        let cached = cacheURL(for: voice)
        if FileManager.default.fileExists(atPath: cached.path) {
            play(cached, voice: voice)
            return
        }

        loadingVoice = voice
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.synthesize(voice)
                try data.write(to: cached, options: .atomic)
                if Task.isCancelled { return }
                self.loadingVoice = nil
                self.play(cached, voice: voice)
            } catch {
                NSLog("[VoicePreview] \(voice.rawValue) failed: \(error.localizedDescription)")
                self.loadingVoice = nil
                AudioCueService.shared.playAgentLaunch()
            }
        }
    }

    func stop() {
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
        playingVoice = nil
        loadingVoice = nil
    }

    // MARK: - Private

    private func play(_ url: URL, voice: MiraVoice) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            AudioCueService.shared.playAgentLaunch()
            return
        }
        p.delegate = self
        p.prepareToPlay()
        player = p
        playingVoice = voice
        p.play()
    }

    private func synthesize(_ voice: MiraVoice) async throws -> Data {
        struct Body: Encodable {
            let model: String
            let voice: String
            let input: String
            let response_format: String
        }
        // In proxy mode the server ignores model/input and uses its own fixed
        // values; sending them keeps direct mode working unchanged.
        let body = Body(
            model: "gpt-4o-mini-tts",
            voice: voice.ttsVoice,
            input: MiraVoice.previewPhrase,
            response_format: "mp3"
        )

        var req = URLRequest(url: MiraBackend.openAITTSURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        req.timeoutInterval = 30
        guard MiraBackend.authorizeOpenAI(&req, directKey: OpenAIService.effectiveKey) else {
            throw MiraError.api("Sign in to preview voices.")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw MiraError.api("TTS: \(msg)")
        }
        return data
    }
}

extension VoicePreviewService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.playingVoice = nil; self.player = nil }
        }
    }
}
