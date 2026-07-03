import Foundation
import AppKit

/// One home for "what song is this?" + every proactive follow-up (turn up/down,
/// skip, favorite, add to playlist, follow artist). It reads the live track from
/// `NowPlayingService` and routes each action to the right backend:
///
/// - **Playback + volume** work locally via AppleScript for both Spotify and Apple
///   Music (no login needed).
/// - **Library writes** (favorite / playlist / follow) need per-user auth. For
///   Spotify that's the Web API via [[SpotifyAuthService]] (PKCE user token). For
///   Apple Music we can do favorite / add-to-playlist locally via AppleScript;
///   "follow artist" isn't an Apple Music concept.
///
/// Both the voice tools (`MiraToolService`) and the chat action chips call in here,
/// so behavior stays identical across surfaces.
@MainActor
final class MusicControlService {
    static let shared = MusicControlService()
    private init() {}

    enum Action: String {
        case volumeUp, volumeDown, next, previous, playPause
        case shuffle, repeatToggle, restart
        case favorite, addToPlaylist, followArtist
    }

    // MARK: - Identify

    /// Fresh spoken/text answer for "what song is this / who's this by / what's
    /// playing". Reads live state so it's correct even before the poll timer fires.
    func identify() async -> String {
        let info = await NowPlayingService.shared.snapshot()
        guard info.hasContent else {
            return "Nothing's playing right now. Want me to start something on Spotify?"
        }
        let on = info.sourceApp.isEmpty ? "" : " on \(info.sourceApp)"
        // Music service with a known artist → "This is X by Y on Spotify."
        if info.isMusicService, !info.artist.isEmpty {
            return "This is \(info.title) by \(info.artist)\(on)."
        }
        // Video / other media → "You're watching X on YouTube."
        if !info.isMusicService, !info.sourceApp.isEmpty {
            return "You're watching \(info.title)\(on)."
        }
        return "This is \(info.title)\(on)."
    }

    /// " on YouTube" / " on Netflix" — appended to playback confirmations for
    /// non-music sources so the user knows what Mira acted on.
    private func sourceSuffix(_ source: String) -> String {
        source.isEmpty ? "" : " on \(source)"
    }

    // MARK: - Perform an action on the current track

    /// Runs a proactive action against whatever is currently playing. `playlist` is
    /// only used by `.addToPlaylist`. Returns a short spoken/text confirmation.
    func perform(_ action: Action, playlist: String? = nil) async -> String {
        let info = await NowPlayingService.shared.snapshot()
        let isSpotify    = info.sourceApp == "Spotify"
        let isAppleMusic = info.sourceApp == "Apple Music"
        let isMusicApp   = isSpotify || isAppleMusic

        switch action {
        // Playback: scriptable music apps use AppleScript; everything else (browser
        // video, QuickTime, …) uses the system media keys via MediaRemote, which
        // work for any app publishing Now Playing info.
        case .playPause:
            if isMusicApp { return appleScriptResult(source: info.sourceApp, spotify: "playpause", music: "playpause", ok: "Toggled playback.") }
            NowPlayingService.shared.togglePlayPause()
            return "Toggled playback\(sourceSuffix(info.sourceApp))."
        case .next:
            if isMusicApp { return appleScriptResult(source: info.sourceApp, spotify: "next track", music: "next track", ok: "Skipped to the next track.") }
            NowPlayingService.shared.nextTrack()
            return "Skipped ahead\(sourceSuffix(info.sourceApp))."
        case .previous:
            if isMusicApp { return appleScriptResult(source: info.sourceApp, spotify: "previous track", music: "previous track", ok: "Went back a track.") }
            NowPlayingService.shared.previousTrack()
            return "Went back\(sourceSuffix(info.sourceApp))."
        case .volumeUp:   return adjustVolume(source: info.sourceApp, delta:  15)
        case .volumeDown: return adjustVolume(source: info.sourceApp, delta: -15)

        case .shuffle:
            guard isMusicApp else { return "Shuffle only works in Spotify or Apple Music." }
            NowPlayingService.shared.toggleShuffle()
            return "Toggled shuffle."
        case .repeatToggle:
            guard isMusicApp else { return "Repeat only works in Spotify or Apple Music." }
            NowPlayingService.shared.toggleRepeat()
            return "Toggled repeat."
        case .restart:
            // Jump the current item back to the start (QuickTime + music apps).
            let app: String? = info.sourceApp == "QuickTime" ? "QuickTime Player"
                             : isSpotify ? "Spotify"
                             : isAppleMusic ? "Music" : nil
            guard let app else { return "I can't restart \(info.sourceApp.isEmpty ? "that" : info.sourceApp)." }
            let target = app == "QuickTime Player" ? "current time of document 1" : "player position"
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"\(app)\" to set \(target) to 0")?.executeAndReturnError(&err)
            return err == nil ? "Restarted from the top." : "I couldn't restart that."

        case .favorite:
            guard info.hasContent else { return "Nothing's playing to favorite." }
            if isSpotify    { return await spotifySave(trackURI: info.trackURI, label: info.title) }
            if isAppleMusic { return appleMusicFavorite(title: info.title) }
            return "Favoriting works for Spotify and Apple Music tracks — you're on \(info.sourceApp.isEmpty ? "another app" : info.sourceApp) right now."

        case .addToPlaylist:
            guard info.hasContent else { return "Nothing's playing to add." }
            let name = (playlist?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            if isSpotify    { return await spotifyAddToPlaylist(trackURI: info.trackURI, title: info.title, playlist: name) }
            if isAppleMusic { return appleMusicAddToPlaylist(title: info.title, playlist: name ?? "Mira") }
            return "Playlists work for Spotify and Apple Music — you're on \(info.sourceApp.isEmpty ? "another app" : info.sourceApp) right now."

        case .followArtist:
            guard info.hasContent else { return "Nothing's playing." }
            if isSpotify { return await spotifyFollowArtist(trackURI: info.trackURI, artist: info.artist) }
            return "Following artists is a Spotify feature — you're on \(info.sourceApp.isEmpty ? "another app" : info.sourceApp) right now."
        }
    }

    // MARK: - Playback / volume (local AppleScript)

    private func appleScriptResult(source: String, spotify: String, music: String, ok: String) -> String {
        let app = source == "Apple Music" ? "Music" : "Spotify"
        let cmd = source == "Apple Music" ? music : spotify
        var err: NSDictionary?
        NSAppleScript(source: "tell application \"\(app)\" to \(cmd)")?.executeAndReturnError(&err)
        if err != nil { return "I couldn't reach \(source.isEmpty ? "your music app" : source)." }
        return ok
    }

    /// Nudges the *source app's* own volume (0–100) so it doesn't fight the system
    /// mixer. Falls back to system volume when nothing is playing.
    private func adjustVolume(source: String, delta: Int) -> String {
        let dir = delta > 0 ? "up" : "down"
        guard source == "Spotify" || source == "Apple Music" else {
            // No known source — nudge the Mac's output volume instead.
            let script = """
            set v to output volume of (get volume settings)
            set n to v + \(delta)
            if n > 100 then set n to 100
            if n < 0 then set n to 0
            set volume output volume n
            return n
            """
            var err: NSDictionary?
            let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
            if err != nil { return "I couldn't change the volume." }
            return "Turned the volume \(dir)\(r?.int32Value != nil ? " to \(r!.int32Value)%" : "")."
        }
        let app = source == "Apple Music" ? "Music" : "Spotify"
        let script = """
        tell application "\(app)"
            set v to sound volume
            set n to v + \(delta)
            if n > 100 then set n to 100
            if n < 0 then set n to 0
            set sound volume to n
            return n
        end tell
        """
        var err: NSDictionary?
        let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { return "I couldn't change \(source)'s volume." }
        let level = r?.int32Value
        return "Turned \(source) \(dir)\(level != nil ? " to \(level!)%" : "")."
    }

    // MARK: - Apple Music library (local AppleScript)

    private func appleMusicFavorite(title: String) -> String {
        // `favorited` is the modern property (macOS Sonoma+); `loved` is the legacy
        // one. Try favorited first, fall back to loved so both OS versions work.
        for prop in ["favorited", "loved"] {
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"Music\" to set \(prop) of current track to true")?
                .executeAndReturnError(&err)
            if err == nil { return "♥ Favorited \(title) in Apple Music." }
        }
        return "I couldn't favorite that in Apple Music."
    }

    private func appleMusicAddToPlaylist(title: String, playlist: String) -> String {
        let safe = playlist.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Music"
            if not (exists playlist "\(safe)") then
                make new playlist with properties {name:"\(safe)"}
            end if
            duplicate current track to playlist "\(safe)"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil { return "I couldn't add \(title) to \(playlist) in Apple Music." }
        return "Added \(title) to \(playlist) in Apple Music."
    }

    // MARK: - Spotify Web API (per-user PKCE token)

    /// Gets a valid user token, launching the consent flow first if the user has
    /// never connected. Returns nil (with a spoken reason via the caller) if the
    /// user cancels or connection fails.
    private func ensureSpotifyToken() async -> String? {
        if let token = await SpotifyAuthService.shared.validAccessToken() { return token }
        let ok = await SpotifyAuthService.shared.connect()
        guard ok else { return nil }
        return await SpotifyAuthService.shared.validAccessToken()
    }

    private static func trackID(from uri: String) -> String? {
        // "spotify:track:abc123" → "abc123"
        guard uri.hasPrefix("spotify:track:") else { return nil }
        let id = uri.replacingOccurrences(of: "spotify:track:", with: "")
        return id.isEmpty ? nil : id
    }

    private func spotifySave(trackURI: String, label: String) async -> String {
        guard let id = Self.trackID(from: trackURI) else {
            return "I couldn't read the current Spotify track."
        }
        guard let token = await ensureSpotifyToken() else {
            return "Connect Spotify in Settings and I'll add tracks to your Liked Songs."
        }
        let ok = await webAPI(method: "PUT", path: "/v1/me/tracks?ids=\(id)", token: token)
        return ok ? "♥ Saved \(label) to your Liked Songs." : "I couldn't save that to your library."
    }

    private func spotifyFollowArtist(trackURI: String, artist: String) async -> String {
        guard let id = Self.trackID(from: trackURI) else {
            return "I couldn't read the current Spotify track."
        }
        guard let token = await ensureSpotifyToken() else {
            return "Connect Spotify in Settings and I'll follow artists for you."
        }
        // The track's artist ID isn't in the AppleScript payload — look it up.
        guard let (artistID, artistName) = await spotifyArtist(forTrackID: id, token: token) else {
            return "I couldn't find that artist on Spotify."
        }
        let ok = await webAPI(method: "PUT", path: "/v1/me/following?type=artist&ids=\(artistID)", token: token)
        let name = artistName.isEmpty ? artist : artistName
        return ok ? "Now following \(name) on Spotify." : "I couldn't follow \(name)."
    }

    private func spotifyAddToPlaylist(trackURI: String, title: String, playlist: String?) async -> String {
        guard !trackURI.isEmpty else { return "I couldn't read the current Spotify track." }
        guard let token = await ensureSpotifyToken() else {
            return "Connect Spotify in Settings and I'll add tracks to your playlists."
        }
        let targetName = playlist ?? "Mira"
        guard let playlistID = await spotifyResolvePlaylist(named: targetName, token: token) else {
            return "I couldn't open the \(targetName) playlist."
        }
        let encoded = trackURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trackURI
        let ok = await webAPI(method: "POST", path: "/v1/playlists/\(playlistID)/tracks?uris=\(encoded)", token: token)
        return ok ? "Added \(title) to your \(targetName) playlist." : "I couldn't add that to \(targetName)."
    }

    // MARK: - Spotify Web API primitives

    /// Fires a Web API call with no response body needed. Returns true on 2xx.
    private func webAPI(method: String, path: String, token: String) async -> Bool {
        guard let url = URL(string: "https://api.spotify.com\(path)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if !(200...299).contains(status) {
                NSLog("[MusicControl] \(method) \(path) → \(status): \(String(data: data, encoding: .utf8) ?? "")")
            }
            return (200...299).contains(status)
        } catch {
            NSLog("[MusicControl] \(method) \(path) error: \(error.localizedDescription)")
            return false
        }
    }

    /// Looks up the first artist (id + name) for a track.
    private func spotifyArtist(forTrackID id: String, token: String) async -> (String, String)? {
        guard let json = await webAPIJSON(path: "/v1/tracks/\(id)", token: token),
              let artists = json["artists"] as? [[String: Any]],
              let first = artists.first,
              let artistID = first["id"] as? String else { return nil }
        return (artistID, (first["name"] as? String) ?? "")
    }

    /// Finds a playlist owned by the user by name (case-insensitive), scanning the
    /// first 50; creates it if missing. Returns the playlist ID.
    private func spotifyResolvePlaylist(named name: String, token: String) async -> String? {
        if let json = await webAPIJSON(path: "/v1/me/playlists?limit=50", token: token),
           let items = json["items"] as? [[String: Any]] {
            if let match = items.first(where: {
                ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame
            }), let id = match["id"] as? String {
                return id
            }
        }
        // Not found — create it under the current user.
        guard let me = await webAPIJSON(path: "/v1/me", token: token),
              let userID = me["id"] as? String else { return nil }
        guard let url = URL(string: "https://api.spotify.com/v1/users/\(userID)/playlists") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "name": name, "public": false,
            "description": "Created by Mira",
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? -1),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String else { return nil }
            return id
        } catch { return nil }
    }

    /// GET that returns a parsed JSON object.
    private func webAPIJSON(path: String, token: String) async -> [String: Any]? {
        guard let url = URL(string: "https://api.spotify.com\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? -1) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }
}
