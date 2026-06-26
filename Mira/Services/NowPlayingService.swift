import Foundation
import AppKit

struct NowPlayingInfo {
    var title:     String   = ""
    var artist:    String   = ""
    var artwork:   NSImage? = nil
    var isPlaying: Bool     = false

    var hasContent: Bool { !title.isEmpty }
}

/// Reads now-playing metadata from any app (Spotify, Apple Music, YouTube Music, etc.)
/// via the MediaRemote private framework loaded at runtime — no link-time dependency.
final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()
    @Published var info = NowPlayingInfo()

    private var timer: Timer?

    // MARK: - MediaRemote function signatures

    private typealias GetInfoFn    = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendCmdFn    = @convention(c) (UInt32, AnyObject?) -> Bool

    private var getInfoFn: GetInfoFn?
    private var sendCmdFn: SendCmdFn?

    // MRMediaRemoteSendCommand constants
    private enum Cmd: UInt32 {
        case togglePlayPause = 2
        case nextTrack       = 4
        case previousTrack   = 5
    }

    init() { loadFramework() }

    // MARK: - Lifecycle

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Controls

    func togglePlayPause() { send(.togglePlayPause) }
    func nextTrack()       { send(.nextTrack) }
    func previousTrack()   { send(.previousTrack) }

    // MARK: - Private

    private func loadFramework() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW
        ) else { return }

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getInfoFn = unsafeBitCast(sym, to: GetInfoFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCmdFn = unsafeBitCast(sym, to: SendCmdFn.self)
        }
    }

    private func fetch() {
        guard let fn = getInfoFn else { return }
        fn(DispatchQueue.main) { [weak self] dict in
            guard let self else { return }
            let title   = dict["kMRMediaRemoteNowPlayingInfoTitle"]       as? String ?? ""
            let artist  = dict["kMRMediaRemoteNowPlayingInfoArtist"]      as? String ?? ""
            let rate    = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            var image: NSImage?
            if let data = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                image = NSImage(data: data)
            }
            self.info = NowPlayingInfo(
                title:     title,
                artist:    artist,
                artwork:   image,
                isPlaying: rate > 0
            )
        }
    }

    private func send(_ cmd: Cmd) {
        _ = sendCmdFn?(cmd.rawValue, nil)
    }
}
