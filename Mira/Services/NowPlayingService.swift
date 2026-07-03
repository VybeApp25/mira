import Foundation
import AppKit

struct NowPlayingInfo {
    var title:       String   = ""
    var artist:      String   = ""
    var artwork:     NSImage? = nil
    var isPlaying:   Bool     = false
    var duration:    Double   = 0       // total track length in seconds
    var elapsedTime: Double   = 0       // elapsed at `timestamp`
    var timestamp:   Date     = .distantPast
    var isShuffled:  Bool     = false
    var isRepeating: Bool     = false
    var sourceApp:   String   = ""      // "Spotify", "Apple Music", "YouTube", … or "" when idle
    var trackURI:    String   = ""      // spotify:track:… when sourced from Spotify

    var hasContent: Bool { !title.isEmpty }

    /// True only for full music services where library actions (favorite / add to
    /// playlist / follow artist) make sense — not for video sources.
    var isMusicService: Bool { sourceApp == "Spotify" || sourceApp == "Apple Music" }

    var currentPosition: Double {
        guard isPlaying, duration > 0 else { return elapsedTime }
        return min(elapsedTime + Date().timeIntervalSince(timestamp), duration)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(currentPosition / duration, 1.0)
    }
}

// Query the active music player via AppleScript.
// MediaRemote returns 0 keys for sandboxed/signed processes on macOS 26;
// AppleScript works because we hold com.apple.security.automation.apple-events.
@MainActor
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()
    @Published var info = NowPlayingInfo()

    private var timer:      Timer?
    private var isStarted   = false
    private var lastArtURL: String = ""  // avoid re-downloading unchanged artwork

    // Which app the current AppleScript-sourced info came from — seek/shuffle/repeat
    // writes target this app specifically rather than guessing. MediaRemote-sourced
    // info (the fast path) has no equivalent write API wired up, so those controls
    // are no-ops until the next AppleScript poll picks up a source.
    private enum MusicSource {
        case none, spotify, appleMusic
        var displayName: String {
            switch self {
            case .none:       return ""
            case .spotify:    return "Spotify"
            case .appleMusic: return "Apple Music"
            }
        }
    }
    private var activeSource: MusicSource = .none

    // MediaRemote — kept as fast path; falls back to AppleScript when keys == 0
    private typealias GetInfoFn  = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendCmdFn  = @convention(c) (UInt32, AnyObject?) -> Bool
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private var getInfoFn:  GetInfoFn?
    private var sendCmdFn:  SendCmdFn?
    private var registerFn: RegisterFn?

    private enum Cmd: UInt32 { case togglePlayPause = 2; case nextTrack = 4; case previousTrack = 5 }

    init() { loadMediaRemote() }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        registerFn?(DispatchQueue.main)
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; isStarted = false }

    // MARK: - Controls (MediaRemote send still works fine)

    func togglePlayPause() { send(.togglePlayPause) }
    func nextTrack()       { send(.nextTrack) }
    func previousTrack()   { send(.previousTrack) }

    /// Seek to an absolute position in seconds. Optimistically updates `info` so the
    /// slider doesn't snap back before the next 2s poll confirms it.
    func seek(to seconds: Double) {
        info.elapsedTime = seconds
        info.timestamp   = Date()
        switch activeSource {
        case .spotify:    runFireAndForget(#"tell application "Spotify" to set player position to \#(seconds)"#)
        case .appleMusic: runFireAndForget(#"tell application "Music" to set player position to \#(seconds)"#)
        case .none:       break
        }
    }

    func toggleShuffle() {
        info.isShuffled.toggle()
        switch activeSource {
        case .spotify:    runFireAndForget(#"tell application "Spotify" to set shuffling to not shuffling"#)
        case .appleMusic: runFireAndForget(#"tell application "Music" to set shuffle enabled to not shuffle enabled"#)
        case .none:       break
        }
    }

    func toggleRepeat() {
        info.isRepeating.toggle()
        switch activeSource {
        case .spotify:
            runFireAndForget(#"tell application "Spotify" to set repeating to not repeating"#)
        case .appleMusic:
            runFireAndForget("""
            tell application "Music"
                if song repeat is off then
                    set song repeat to all
                else
                    set song repeat to off
                end if
            end tell
            """)
        case .none:
            break
        }
    }

    private func runFireAndForget(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.launchPath = "/usr/bin/osascript"
            p.arguments  = ["-e", source]
            p.standardOutput = Pipe()
            p.standardError  = Pipe()
            try? p.run()
        }
    }

    // MARK: - Poll: try MediaRemote first, fall back to AppleScript

    private func poll() {
        guard let fn = getInfoFn else { fetchViaAppleScript(); return }
        fn(DispatchQueue.main) { [weak self] dict in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if dict.count > 0 {
                    // MediaRemote delivered data — use it
                    let title   = dict["kMRMediaRemoteNowPlayingInfoTitle"]        as? String ?? ""
                    let artist  = dict["kMRMediaRemoteNowPlayingInfoArtist"]       as? String ?? ""
                    let rate    = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                    let dur     = dict["kMRMediaRemoteNowPlayingInfoDuration"]     as? Double ?? 0
                    let elapsed = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"]  as? Double ?? 0
                    let ts      = dict["kMRMediaRemoteNowPlayingInfoTimestamp"]    as? Date   ?? Date()
                    var image: NSImage? = self.info.artwork
                    if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, data.count > 0,
                       let img = NSImage(data: data), img.isValid { image = img }
                    self.info = NowPlayingInfo(title: title, artist: artist, artwork: image,
                                              isPlaying: rate > 0, duration: dur,
                                              elapsedTime: elapsed, timestamp: ts)
                } else {
                    // MediaRemote returned nothing — fall back to AppleScript
                    self.fetchViaAppleScript()
                }
            }
        }
    }

    // MARK: - AppleScript fallback (Spotify → Apple Music → nothing)

    private func fetchViaAppleScript() {
        Task.detached(priority: .userInitiated) { [weak self] in
            // Try Spotify first
            if let result = await Self.querySpotify() {
                await MainActor.run { [weak self] in self?.applyResult(result, source: .spotify) }
                return
            }
            // Try Apple Music
            if let result = await Self.queryAppleMusic() {
                await MainActor.run { [weak self] in self?.applyResult(result, source: .appleMusic) }
                return
            }
            // Then anything else: QuickTime / browser video (YouTube, Netflix, …)
            if let generic = await Self.queryGenericMedia() {
                // Re-download artwork only when the poster URL actually changes, so
                // the 2s poll doesn't refetch the same thumbnail every cycle.
                let lastURL = await MainActor.run { self?.lastArtURL ?? "" }
                let existing = await MainActor.run { self?.info.artwork }
                let art = (generic.artworkURL == lastURL)
                    ? existing
                    : await Self.downloadArtwork(generic.artworkURL)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.activeSource = .none
                    self.lastArtURL = generic.artworkURL
                    var info = NowPlayingInfo()
                    info.title     = generic.title
                    info.artist    = generic.artist
                    info.sourceApp = generic.source
                    info.isPlaying = true
                    info.artwork   = art
                    self.info = info
                }
                return
            }
            // Nothing playing
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeSource = .none
                if self.info.hasContent {
                    self.info = NowPlayingInfo()
                }
            }
        }
    }

    /// Downloads artwork off the main thread; nil URL / failure → nil image.
    private static func downloadArtwork(_ urlString: String) async -> NSImage? {
        guard !urlString.isEmpty, let url = URL(string: urlString),
              let data = try? Data(contentsOf: url),
              let img = NSImage(data: data), img.isValid else { return nil }
        return img
    }

    private func applyResult(_ r: ScriptResult, source: MusicSource) {
        activeSource = source
        Task.detached(priority: .background) { [weak self] in
            var image: NSImage? = await MainActor.run { self?.info.artwork }
            // Re-download artwork only when URL changes
            let lastURL = await MainActor.run { self?.lastArtURL ?? "" }
            if r.artworkURL != lastURL, let url = URL(string: r.artworkURL),
               let data = try? Data(contentsOf: url),
               let img  = NSImage(data: data), img.isValid {
                image = img
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastArtURL = r.artworkURL
                self.info = NowPlayingInfo(
                    title:       r.title,
                    artist:      r.artist,
                    artwork:     image,
                    isPlaying:   r.isPlaying,
                    duration:    r.duration,
                    elapsedTime: r.position,
                    timestamp:   Date(),
                    isShuffled:  r.shuffled,
                    isRepeating: r.repeating,
                    sourceApp:   source.displayName,
                    trackURI:    r.trackURI
                )
            }
        }
    }

    // MARK: - AppleScript helpers

    private struct ScriptResult {
        var title: String; var artist: String; var isPlaying: Bool
        var duration: Double; var position: Double; var artworkURL: String
        var shuffled: Bool; var repeating: Bool; var trackURI: String = ""
    }

    private static func querySpotify() async -> ScriptResult? {
        let src = """
        tell application "Spotify"
            if it is running then
                set s to (player state as string)
                set t to name of current track
                set a to artist of current track
                set d to (duration of current track as real)
                set p to (player position as real)
                set u to artwork url of current track
                set sh to (shuffling as string)
                set rp to (repeating as string)
                set tid to (id of current track as string)
                return s & "|||" & t & "|||" & a & "|||" & d & "|||" & p & "|||" & u & "|||" & sh & "|||" & rp & "|||" & tid
            end if
        end tell
        """
        return parse(await runScript(src), durationInMs: true)
    }

    // MARK: - Public one-shot snapshot (fresh query, awaits a result)

    /// Forces a fresh query (Spotify → Apple Music) and returns the current track
    /// info WITHOUT waiting on the 2-second poll or artwork download. Used by the
    /// music tools so "what song is this?" reads live state even if the poll timer
    /// hasn't run yet. Also refreshes the published `info` for any UI observers.
    func snapshot() async -> NowPlayingInfo {
        // Music services first (richest metadata + library actions).
        if let r = await Self.querySpotify() {
            let info = build(r, source: .spotify)
            self.activeSource = .spotify
            self.info = info
            return info
        }
        if let r = await Self.queryAppleMusic() {
            let info = build(r, source: .appleMusic)
            self.activeSource = .appleMusic
            self.info = info
            return info
        }
        // Then any other media: QuickTime, or a browser tab on a media site
        // (YouTube, Netflix, Hulu, Twitch, …). These use MediaRemote/media-key
        // controls; no library actions.
        if let generic = await Self.queryGenericMedia() {
            let art = await Self.downloadArtwork(generic.artworkURL)
            self.activeSource = .none   // not a scriptable music app
            var info = NowPlayingInfo()
            info.title     = generic.title
            info.artist    = generic.artist
            info.sourceApp = generic.source
            info.isPlaying = true
            info.artwork   = art
            self.info = info
            return info
        }
        self.activeSource = .none
        let empty = NowPlayingInfo()
        self.info = empty
        return empty
    }

    /// A non-music-service media item (video/other). `artist` may be empty;
    /// `artworkURL` is a poster/thumbnail when we can derive one (e.g. YouTube).
    private struct GenericMedia { var title: String; var artist: String; var source: String; var artworkURL: String = "" }

    /// Detects "everything else": QuickTime Player, then the frontmost media tab in
    /// a running browser. Returns nil if nothing media-like is found.
    private static func queryGenericMedia() async -> GenericMedia? {
        if let qt = await queryQuickTime() { return qt }
        if let web = await queryBrowserMedia() { return web }
        return nil
    }

    /// Localized names of currently-running apps — lets us skip AppleScript for
    /// anything not open (cheap, and avoids spawning osascript 8× every poll).
    private static func runningAppNames() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.localizedName })
    }

    private static func queryQuickTime() async -> GenericMedia? {
        guard runningAppNames().contains("QuickTime Player") else { return nil }
        let src = """
        tell application "QuickTime Player"
            if it is running and (count of documents) > 0 then
                set t to name of document 1
                return t
            end if
        end tell
        """
        let out = await runScript(src).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        return GenericMedia(title: out, artist: "", source: "QuickTime")
    }

    // host substring → friendly service name. Order doesn't matter; first hit wins.
    private static let mediaHosts: [(String, String)] = [
        ("youtube.com", "YouTube"), ("youtu.be", "YouTube"), ("music.youtube", "YouTube Music"),
        ("netflix.com", "Netflix"), ("hulu.com", "Hulu"), ("disneyplus.com", "Disney+"),
        ("max.com", "Max"), ("hbomax.com", "Max"), ("primevideo.com", "Prime Video"),
        ("amazon.com", "Prime Video"), ("twitch.tv", "Twitch"), ("vimeo.com", "Vimeo"),
        ("peacocktv.com", "Peacock"), ("paramountplus.com", "Paramount+"), ("tv.apple.com", "Apple TV"),
        ("soundcloud.com", "SoundCloud"), ("open.spotify.com", "Spotify Web"), ("music.apple.com", "Apple Music Web"),
        ("crunchyroll.com", "Crunchyroll"), ("espn.com", "ESPN"),
    ]

    /// Reads the frontmost tab of whichever supported browser is running and, if
    /// it's on a known media site, returns its (cleaned) title. Safari and the
    /// Chromium family (Chrome/Brave/Edge/Arc/Atlas) use different AppleScript
    /// dialects, so we try each running browser in turn.
    private static func queryBrowserMedia() async -> GenericMedia? {
        // (appName, dialect): "safari" or "chromium"
        let browsers: [(String, String)] = [
            ("Safari", "safari"),
            ("Google Chrome", "chromium"), ("Brave Browser", "chromium"),
            ("Microsoft Edge", "chromium"), ("Arc", "chromium"),
            ("ChatGPT Atlas", "chromium"), ("Vivaldi", "chromium"), ("Opera", "chromium"),
        ]
        let running = runningAppNames()
        for (app, dialect) in browsers where running.contains(app) {
            let tabExpr = dialect == "safari"
                ? "current tab of front window"
                : "active tab of front window"
            let titleKey = dialect == "safari" ? "name" : "title"
            let src = """
            tell application "\(app)"
                if it is running and (count of windows) > 0 then
                    set theURL to URL of \(tabExpr)
                    set theTitle to \(titleKey) of \(tabExpr)
                    return theURL & "|||" & theTitle
                end if
            end tell
            """
            let out = await runScript(src).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "|||")
            guard parts.count >= 2 else { continue }
            let rawURL = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let url    = rawURL.lowercased()
            let title  = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (_, service) = mediaHosts.first(where: { url.contains($0.0) }),
                  !title.isEmpty else { continue }
            return GenericMedia(title: cleanTitle(title, service: service), artist: "",
                                source: service, artworkURL: posterURL(forURL: rawURL, service: service))
        }
        return nil
    }

    /// Best-effort poster/thumbnail for a media tab. YouTube exposes a reliable
    /// thumbnail by video ID; other services don't have a public per-title image
    /// URL, so those return "" and the UI shows a source placeholder.
    private static func posterURL(forURL url: String, service: String) -> String {
        guard service == "YouTube" || service == "YouTube Music" else { return "" }
        // Pull the 11-char video ID from watch?v=… or youtu.be/…
        if let comps = URLComponents(string: url) {
            if let v = comps.queryItems?.first(where: { $0.name == "v" })?.value, v.count >= 8 {
                return "https://img.youtube.com/vi/\(v)/hqdefault.jpg"
            }
            if comps.host?.contains("youtu.be") == true {
                let id = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if id.count >= 8 { return "https://img.youtube.com/vi/\(id)/hqdefault.jpg" }
            }
        }
        return ""
    }

    /// Strips the site name a browser appends to the tab title
    /// ("Never Gonna Give You Up - YouTube" → "Never Gonna Give You Up").
    private static func cleanTitle(_ title: String, service: String) -> String {
        var t = title
        let suffixes = [" - YouTube", " | Netflix", " - Twitch", " on Vimeo",
                        " - Hulu", " | Disney+", " | Prime Video", " | Max",
                        " | Paramount+", " - Crunchyroll", " | SoundCloud"]
        for s in suffixes where t.hasSuffix(s) { t = String(t.dropLast(s.count)) }
        // Generic trailing " - <service>" / " | <service>"
        for sep in [" - ", " | "] {
            if let r = t.range(of: sep + service, options: [.caseInsensitive, .backwards]) {
                t = String(t[..<r.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func build(_ r: ScriptResult, source: MusicSource) -> NowPlayingInfo {
        NowPlayingInfo(
            title:       r.title,
            artist:      r.artist,
            artwork:     info.title == r.title ? info.artwork : nil,
            isPlaying:   r.isPlaying,
            duration:    r.duration,
            elapsedTime: r.position,
            timestamp:   Date(),
            isShuffled:  r.shuffled,
            isRepeating: r.repeating,
            sourceApp:   source.displayName,
            trackURI:    r.trackURI
        )
    }

    private static func queryAppleMusic() async -> ScriptResult? {
        let src = """
        tell application "Music"
            if it is running and player state is playing then
                set t to name of current track
                set a to artist of current track
                set d to (duration of current track as real)
                set p to (player position as real)
                set sh to (shuffle enabled as string)
                set rp to (song repeat as string)
                return "playing|||" & t & "|||" & a & "|||" & d & "|||" & p & "|||" & "|||" & sh & "|||" & rp
            end if
        end tell
        """
        return parse(await runScript(src), durationInMs: false)
    }

    private static func parse(_ output: String, durationInMs: Bool) -> ScriptResult? {
        guard !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 5 else { return nil }
        let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var dur = Double(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if durationInMs { dur /= 1000.0 }
        let shuffledStr  = parts.count > 6 ? parts[6].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let repeatingStr = parts.count > 7 ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let trackURI     = parts.count > 8 ? parts[8].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return ScriptResult(
            title:      title,
            artist:     parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            isPlaying:  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "playing",
            duration:   dur,
            position:   Double(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            artworkURL: parts.count > 5 ? parts[5].trimmingCharacters(in: .whitespacesAndNewlines) : "",
            shuffled:   shuffledStr == "true",
            repeating:  repeatingStr == "true" || repeatingStr == "all" || repeatingStr == "one",
            trackURI:   trackURI
        )
    }

    private static func runScript(_ source: String) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.launchPath  = "/usr/bin/osascript"
                p.arguments   = ["-e", source]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError  = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - MediaRemote loading

    private func loadMediaRemote() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW
        ) else { return }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")          { getInfoFn  = unsafeBitCast(sym, to: GetInfoFn.self)  }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand")                { sendCmdFn  = unsafeBitCast(sym, to: SendCmdFn.self)  }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") { registerFn = unsafeBitCast(sym, to: RegisterFn.self) }
    }

    private func send(_ cmd: Cmd) { _ = sendCmdFn?(cmd.rawValue, nil) }
}
