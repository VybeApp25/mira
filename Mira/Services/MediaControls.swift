import Foundation

/// One tappable/​speakable control, tailored to the app that's playing.
struct MediaChip: Equatable, Identifiable {
    var id: String { action + label }
    let icon:   String
    let label:  String
    let action: String   // MusicControlService.Action raw value
}

/// Decides WHICH controls Mira offers for the app that's currently playing.
///
/// The available actions differ per app: Spotify can favorite / add-to-playlist /
/// follow / shuffle; Apple Music can favorite / playlist / shuffle (no follow);
/// Netflix/Hulu skip to the "next episode"; QuickTime can restart; a plain video
/// site only gets play + volume. Both the chat action chips and the voice-facing
/// capability hints read from here, so the two surfaces stay in sync.
enum MediaControls {

    // Common building blocks
    private static let playPause  = MediaChip(icon: "playpause.fill",         label: "Play/Pause", action: "playPause")
    private static let prev       = MediaChip(icon: "backward.fill",          label: "Previous",   action: "previous")
    private static let skip       = MediaChip(icon: "forward.fill",           label: "Skip",       action: "next")
    private static let nextEp      = MediaChip(icon: "forward.end.fill",       label: "Next episode", action: "next")
    private static let volUp      = MediaChip(icon: "speaker.wave.3.fill",    label: "Turn up",    action: "volumeUp")
    private static let volDown    = MediaChip(icon: "speaker.wave.1.fill",    label: "Turn down",  action: "volumeDown")
    private static let shuffle    = MediaChip(icon: "shuffle",                label: "Shuffle",    action: "shuffle")
    private static let repeatCh   = MediaChip(icon: "repeat",                 label: "Repeat",     action: "repeatToggle")
    private static let favorite   = MediaChip(icon: "heart.fill",             label: "Favorite",   action: "favorite")
    private static let playlist   = MediaChip(icon: "text.badge.plus",        label: "Add to playlist", action: "addToPlaylist")
    private static let follow     = MediaChip(icon: "person.fill.badge.plus", label: "Follow artist",   action: "followArtist")
    private static let restart    = MediaChip(icon: "gobackward",             label: "Restart",    action: "restart")

    /// The tailored chip set for a given `sourceApp` string (as set by
    /// NowPlayingService: "Spotify", "Apple Music", "YouTube", "Netflix", …).
    static func chips(for sourceApp: String) -> [MediaChip] {
        switch sourceApp {
        case "Spotify":
            return [playPause, skip, volUp, volDown, shuffle, favorite, playlist, follow]
        case "Apple Music", "Apple Music Web":
            return [playPause, skip, volUp, volDown, shuffle, favorite, playlist]
        case "SoundCloud", "Spotify Web", "YouTube Music":
            // Web audio players: full transport, no library writes.
            return [playPause, prev, skip, volUp, volDown]
        case "QuickTime":
            return [playPause, volUp, volDown, restart]
        case "Netflix", "Hulu", "Disney+", "Max", "Prime Video",
             "Peacock", "Paramount+", "Apple TV", "Crunchyroll":
            // Streaming video: episode transport + volume.
            return [playPause, nextEp, volUp, volDown]
        case "YouTube":
            return [playPause, skip, volUp, volDown]
        default:
            // Twitch / Vimeo / ESPN / anything else: safest common set.
            return [playPause, volUp, volDown]
        }
    }

    /// "listening to" for music, "watching" for video — used in spoken/text replies.
    static func verb(for sourceApp: String) -> String {
        let music = ["Spotify", "Apple Music", "Apple Music Web", "Spotify Web",
                     "SoundCloud", "YouTube Music"]
        return music.contains(sourceApp) ? "listening to" : "watching"
    }
}
