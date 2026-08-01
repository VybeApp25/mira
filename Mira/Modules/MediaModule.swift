// MediaModule.swift
// MacNotch's Media module: album art with gradients, full transport, and a
// visualisation. The audit scored Mira 🟡 — NowPlayingService already had
// transport, seek, shuffle and repeat; what was missing was a panel built
// around them.
//
// Reuses ArtworkAccent from the collapsed ears so the expanded panel and the
// closed pill are tinted from the same album. That consistency is the point:
// opening the notch on a playing track should feel like the same object
// growing, not like a different screen.
//
// Playback position is INTERPOLATED. NowPlayingService polls, so `elapsedTime`
// is a snapshot taken at `timestamp`; rendering it directly makes the scrubber
// jump in poll-sized steps. Advancing it from the timestamp gives a smooth bar
// without polling harder.
//
// Not built: synced lyrics. That needs a lyrics source Mira doesn't have, and
// faking it would be worse than omitting it.

import SwiftUI
import AppKit
import Combine

@MainActor
final class MediaModule: NotchModule, ObservableObject {

    let id    = "media"
    let title = "Media"

    var icon: String {
        NowPlayingService.shared.info.isPlaying ? "play.circle.fill" : "music.note"
    }

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = false

    private let service = NowPlayingService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        let src = service.info.sourceApp
        guard !src.isEmpty else { return nil }
        return NotchHeaderSubtitle(text: src)
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear() { service.start() }

    func makeContent() -> AnyView { AnyView(MediaModuleView(service: service)) }
}

// MARK: - View

private struct MediaModuleView: View {

    @ObservedObject var service: NowPlayingService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var info: NowPlayingInfo { service.info }
    private var accent: Color { ArtworkAccent.color(for: info.artwork) }

    var body: some View {
        ZStack {
            backdrop
            if info.title.isEmpty {
                empty
            } else {
                content
            }
        }
    }

    /// Gradient pulled from the artwork, dark enough to keep text legible.
    private var backdrop: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [accent.opacity(0.30), accent.opacity(0.06), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    private var content: some View {
        HStack(spacing: 14) {
            artwork
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                Text(info.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                if !info.artist.isEmpty {
                    Text(info.artist)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.60))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                scrubber
                Spacer(minLength: 6)
                transport
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, NotchModuleShellView.headerHeight + 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: Artwork

    @ViewBuilder
    private var artwork: some View {
        Group {
            if let art = info.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.40))
                    )
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }

    // MARK: Scrubber

    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let pos = currentPosition
            let total = max(info.duration, 1)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(accent)
                            .frame(width: geo.size.width * CGFloat(min(pos / total, 1)))
                    }
                    .contentShape(Rectangle())
                    // Click anywhere on the bar to seek there.
                    .onTapGesture { location in
                        let fraction = max(0, min(1, location.x / geo.size.width))
                        service.seek(to: fraction * total)
                    }
                }
                .frame(height: 4)

                HStack {
                    Text(timeString(pos))
                    Spacer()
                    Text(timeString(total))
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
            }
        }
    }

    /// Interpolated from the last poll so the bar advances smoothly.
    private var currentPosition: Double {
        guard info.isPlaying else { return info.elapsedTime }
        let since = Date().timeIntervalSince(info.timestamp)
        return min(info.elapsedTime + max(0, since), max(info.duration, 0))
    }

    private func timeString(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 16) {
            button("shuffle", active: info.isShuffled, size: 12) { service.toggleShuffle() }
            button("backward.fill", size: 14) { service.previousTrack() }

            Button { service.togglePlayPause() } label: {
                Image(systemName: info.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.black)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(info.isPlaying ? "Pause" : "Play")

            button("forward.fill", size: 14) { service.nextTrack() }
            button("repeat", active: info.isRepeating, size: 12) { service.toggleRepeat() }

            Spacer(minLength: 0)

            MediaLevelBars(isPlaying: info.isPlaying, tint: accent, reduceMotion: reduceMotion)
                .frame(width: 26, height: 16)
        }
    }

    private func button(_ icon: String,
                        active: Bool = false,
                        size: CGFloat,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(active ? accent : .white.opacity(0.70))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon)
    }

    private var empty: some View {
        VStack(spacing: 5) {
            Image(systemName: "music.note")
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.22))
            Text("Nothing playing")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.50))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Level bars

/// Real levels, from a real FFT over the system audio Mira is already permitted
/// to capture (AudioSpectrumService).
///
/// This used to be six sin() waves — identical motion for silence, a podcast and
/// a drum solo. The previous comment was honest that it was "plausible motion,
/// not an FFT… Mira has no tap on system audio output"; that second half stopped
/// being true once SystemAudioCapture existed for call transcription, so there
/// was no longer a reason to fake it.
///
/// Falls back to the flat idle bars whenever the capture is not running (no
/// Screen Recording grant, nothing playing), because a frozen last-value would
/// be the same lie in a quieter form.
private struct MediaLevelBars: View {
    let isPlaying: Bool
    let tint: Color
    let reduceMotion: Bool

    private static let barCount = AudioSpectrumService.bandCount

    @ObservedObject private var spectrum = AudioSpectrumService.shared

    var body: some View {
        Group {
            if reduceMotion || !isPlaying || !spectrum.isRunning {
                bars { _ in 0.25 }
            } else {
                bars { index in
                    // A bar pinned at zero reads as broken rather than quiet, so
                    // the floor stays at the idle height.
                    0.25 + 0.75 * (spectrum.levels.indices.contains(index)
                                   ? spectrum.levels[index] : 0)
                }
                .animation(.linear(duration: 0.08), value: spectrum.levels)
            }
        }
        .onAppear { if isPlaying { spectrum.retain() } }
        .onDisappear { if isPlaying { spectrum.release() } }
        .onChange(of: isPlaying) { _, playing in
            // Capture follows playback: no audio, no reason to be listening.
            playing ? spectrum.retain() : spectrum.release()
        }
    }

    private func bars(_ height: @escaping (Int) -> Double) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: height(i), anchor: .center)
            }
        }
    }
}
