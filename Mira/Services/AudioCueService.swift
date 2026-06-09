import AppKit
import Foundation

// MARK: - Audio cue service
//
// Sound palette for Mira's notch pill. All sounds are opt-out per cue;
// global mute is respected; repeated cues are rate-limited to 1.5 s so
// rapid mode flicker doesn't spam sounds.
//
// Audio is never the sole indicator — all cues have VoiceOver + visual alternatives.

@MainActor
final class AudioCueService {
    static let shared = AudioCueService()

    // MARK: - Global mute

    var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: "mira_audio_muted") }
        set { UserDefaults.standard.set(newValue, forKey: "mira_audio_muted") }
    }

    // MARK: - Per-cue toggles (default enabled)

    func isCueEnabled(_ name: String) -> Bool {
        let key = "mira_audio_cue_\(name)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    func setCueEnabled(_ name: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "mira_audio_cue_\(name)")
    }

    // MARK: - Rate limiting

    private var lastPlayed: [String: Date] = [:]
    private let rateLimitInterval: TimeInterval = 1.5

    private func shouldPlay(_ name: String) -> Bool {
        guard !isMuted, isCueEnabled(name) else { return false }
        if let last = lastPlayed[name],
           Date().timeIntervalSince(last) < rateLimitInterval { return false }
        return true
    }

    // MARK: - Public API

    func playModeChange(_ mode: PillMode) {
        switch mode {
        case .thinking: play("thinking", sound: "Tink")
        case .speaking: play("speaking", sound: "Pop")
        case .working:  break   // no sound for working — visual indicator is sufficient
        case .idle:     break
        }
    }

    func playEvent(_ event: PillEvent) {
        switch event {
        case .shortcut:  play("invoke",    sound: "Ping")
        case .complete:  play("complete",  sound: "Glass")
        case .error:     play("error",     sound: "Funk")
        case .listening: play("listening", sound: "Tink")
        case .handoff:   break
        }
    }

    // MARK: - Private

    private func play(_ name: String, sound: String) {
        guard shouldPlay(name) else { return }
        lastPlayed[name] = Date()
        NSSound(named: NSSound.Name(sound))?.play()
    }
}
