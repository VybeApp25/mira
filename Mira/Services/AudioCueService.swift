import AVFoundation
import AppKit
import Foundation

// MARK: - Sound catalog

enum MiraSound: String, CaseIterable {
    // Agent lifecycle (HeyClicky mp3s)
    case agentLaunch   = "agent-launch"
    case agentDone     = "agent-done"
    case agentClose    = "agent-close"
    // Interaction
    case enter         = "enter"
    case textSend      = "clicky-text-send"
    case textReceive   = "clicky-text-receive"
    case skillUp       = "skill-up"
    case skillDown     = "skill-down"

    var fileExtension: String {
        switch self {
        case .agentLaunch, .agentDone, .agentClose, .enter: return "mp3"
        default: return "wav"
        }
    }
}

// MARK: - AudioCueService

@MainActor
final class AudioCueService {
    static let shared = AudioCueService()
    private init() { preload() }

    // MARK: - Settings

    var isMuted: Bool {
        get { UserDefaults.standard.bool(forKey: "mira_audio_muted") }
        set { UserDefaults.standard.set(newValue, forKey: "mira_audio_muted") }
    }

    func isCueEnabled(_ name: String) -> Bool {
        let key = "mira_audio_cue_\(name)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    func setCueEnabled(_ name: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "mira_audio_cue_\(name)")
    }

    // MARK: - Player pool (8 simultaneous cues)

    private var players: [MiraSound: AVAudioPlayer] = [:]
    private var lastPlayed: [MiraSound: Date] = [:]
    private let rateLimitInterval: TimeInterval = 1.5

    private func preload() {
        for sound in MiraSound.allCases {
            if let url = Bundle.main.url(forResource: sound.rawValue, withExtension: sound.fileExtension),
               let player = try? AVAudioPlayer(contentsOf: url) {
                player.prepareToPlay()
                players[sound] = player
            }
        }
    }

    // MARK: - Public API

    func play(_ sound: MiraSound) {
        guard !isMuted, isCueEnabled(sound.rawValue) else { return }
        if let last = lastPlayed[sound],
           Date().timeIntervalSince(last) < rateLimitInterval { return }
        lastPlayed[sound] = Date()

        if let player = players[sound] {
            // Reset and play
            if player.isPlaying { player.stop() }
            player.currentTime = 0
            player.play()
        } else {
            // Fallback to system sound if bundle file missing
            NSSound(named: NSSound.Name(fallbackName(sound)))?.play()
        }
    }

    // MARK: - Named convenience methods (used by existing callers)

    func playModeChange(_ mode: PillMode) {
        switch mode {
        case .thinking:  play(.skillUp)
        case .speaking:  play(.textReceive)
        case .listening: play(.enter)
        case .working:   break
        case .idle:      break
        }
    }

    func playEvent(_ event: PillEvent) {
        switch event {
        case .shortcut:  play(.enter)
        case .complete:  play(.agentDone)
        case .error:     play(.skillDown)
        case .listening: play(.textSend)
        case .handoff:   play(.skillUp)
        }
    }

    func playAgentLaunch()    { play(.agentLaunch) }
    func playAgentComplete()  { play(.agentDone) }
    func playAgentClose()     { play(.agentClose) }
    func playAgentBlocked()   { play(.skillDown) }
    func playTextSend()       { play(.textSend) }
    func playTextReceive()    { play(.textReceive) }

    // MARK: - ChimeWarmer
    // Plays a silent 0-volume note through the audio pipeline at launch to prime
    // the hardware and eliminate any first-play latency spike (HeyClicky's ClickyChimeWarmer).

    func warmHardware() {
        guard let player = players[.enter] else { return }
        let savedVolume  = player.volume
        player.volume    = 0
        player.currentTime = 0
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            player.stop()
            player.volume = savedVolume
            player.currentTime = 0
        }
    }

    // MARK: - Private

    private func fallbackName(_ sound: MiraSound) -> String {
        switch sound {
        case .agentLaunch:  return "Purr"
        case .agentDone:    return "Hero"
        case .agentClose:   return "Pop"
        case .enter:        return "Ping"
        case .textSend:     return "Tink"
        case .textReceive:  return "Pop"
        case .skillUp:      return "Tink"
        case .skillDown:    return "Funk"
        }
    }
}
