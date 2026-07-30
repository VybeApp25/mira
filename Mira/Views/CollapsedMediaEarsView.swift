// CollapsedMediaEarsView.swift
// Media presentation for the CLOSED notch, in the ears rather than below it.
//
// The first version put a small icon and a line of text in the drop strip under
// the cutout. That is the wrong place: MacNotch uses the EARS — the empty
// menu-bar space either side of the camera cutout — with album art on the left
// and a moving waveform on the right. Content beside the notch reads as part of
// the hardware; content hanging below it reads as a banner the app is showing you.
//
// Three things this fixes at once:
//   • Position — art left, waveform right, both at menu-bar height.
//   • Proportion — the pill spans art + cutout + waveform, so it is wide and
//     shallow instead of tall with a dangling strip.
//   • Track change — MacNotch widens briefly to show what just started, then
//     settles back to the compact form. `TrackChangeMonitor` drives that here.
//
// Typography note: the title is the only text, at 11pt medium. The artist is
// dropped in the compact form on purpose — two lines of metadata in a 30pt strip
// is what made the first attempt feel cramped.

import SwiftUI
import AppKit

// MARK: - Track-change detection

/// Publishes a brief "just changed" window so the pill can widen and name the
/// new track, then settle. Watches title+artist rather than any elapsed-time
/// field, so a normal position tick never counts as a change.
@MainActor
final class TrackChangeMonitor: ObservableObject {

    static let shared = TrackChangeMonitor()

    /// True for `expandedWindow` seconds after a new track starts.
    @Published private(set) var justChanged = false

    private static let expandedWindow: TimeInterval = 3.5
    private var lastKey = ""
    private var resetWork: DispatchWorkItem?

    private init() {}

    /// Called from the view as Now Playing updates.
    func note(title: String, artist: String) {
        let key = "\(title)|\(artist)"
        guard key != lastKey else { return }
        let hadPrevious = !lastKey.isEmpty
        lastKey = key
        guard hadPrevious, !title.isEmpty else { return }   // don't fire on first load

        resetWork?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { justChanged = true }

        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                self?.justChanged = false
            }
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandedWindow, execute: work)
    }
}

// MARK: - View

struct CollapsedMediaEarsView: View {

    @ObservedObject private var nowPlaying = NowPlayingService.shared
    @ObservedObject private var trackChange = TrackChangeMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the hardware (or synthesised) cutout to leave clear between ears.
    let notchWidth: CGFloat

    private var info: NowPlayingInfo { nowPlaying.info }

    var body: some View {
        HStack(spacing: 0) {
            leftEar
            // The cutout itself — nothing may be drawn here, the camera occludes it.
            Color.clear.frame(width: notchWidth)
            rightEar
        }
        .onChange(of: info.title) { _, _ in
            trackChange.note(title: info.title, artist: info.artist)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.artist.isEmpty
                            ? "Playing \(info.title)"
                            : "Playing \(info.title) by \(info.artist)")
    }

    // MARK: - Left ear: artwork (+ title while a track change is fresh)

    private var leftEar: some View {
        HStack(spacing: 7) {
            artwork
            if trackChange.justChanged {
                VStack(alignment: .leading, spacing: 0) {
                    Text(info.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                    if !info.artist.isEmpty {
                        Text(info.artist)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.50))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 150, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
    }

    @ViewBuilder
    private var artwork: some View {
        if let art = info.artwork {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
        } else {
            // Placeholder keeps the ear's width stable while artwork loads, so
            // the pill doesn't jitter a moment after a track starts.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.10))
                .frame(width: 20, height: 20)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                )
        }
    }

    // MARK: - Right ear: waveform

    private var rightEar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            MediaWaveform(isPlaying: info.isPlaying, reduceMotion: reduceMotion)
                .frame(width: 26, height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 12)
    }
}

// MARK: - Waveform

/// Five bars on staggered sine phases. Deliberately not an FFT of the audio —
/// Mira has no tap on system audio output here, and a plausible motion at 30fps
/// is what the eye reads as "playing" anyway. Freezes flat when paused, which is
/// the one thing it must get honestly right.
private struct MediaWaveform: View {

    let isPlaying: Bool
    let reduceMotion: Bool

    private static let bars = 5
    private static let phases: [Double] = [0.0, 0.9, 1.8, 0.45, 1.35]
    private static let speeds: [Double] = [3.1, 2.4, 3.6, 2.8, 3.3]

    var body: some View {
        if reduceMotion || !isPlaying {
            staticBars
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                bars { i in
                    let s = sin(t * Self.speeds[i] + Self.phases[i])
                    return 0.30 + 0.70 * (s * s)   // sin² keeps it positive and lively
                }
            }
        }
    }

    private var staticBars: some View {
        bars { _ in 0.28 }
    }

    private func bars(_ height: @escaping (Int) -> Double) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.bars, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.80))
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: height(i), anchor: .center)
            }
        }
    }
}
