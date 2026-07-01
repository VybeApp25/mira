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

    var hasContent: Bool { !title.isEmpty }

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
    private enum MusicSource { case none, spotify, appleMusic }
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
                    isRepeating: r.repeating
                )
            }
        }
    }

    // MARK: - AppleScript helpers

    private struct ScriptResult {
        var title: String; var artist: String; var isPlaying: Bool
        var duration: Double; var position: Double; var artworkURL: String
        var shuffled: Bool; var repeating: Bool
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
                return s & "|||" & t & "|||" & a & "|||" & d & "|||" & p & "|||" & u & "|||" & sh & "|||" & rp
            end if
        end tell
        """
        return parse(await runScript(src), durationInMs: true)
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
        return ScriptResult(
            title:      title,
            artist:     parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            isPlaying:  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "playing",
            duration:   dur,
            position:   Double(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0,
            artworkURL: parts.count > 5 ? parts[5].trimmingCharacters(in: .whitespacesAndNewlines) : "",
            shuffled:   shuffledStr == "true",
            repeating:  repeatingStr == "true" || repeatingStr == "all" || repeatingStr == "one"
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
